#!/usr/bin/env python3
"""A stand-in for MLX Studio's local API, for working on Earshot without loading models.

It reproduces the parts of vMLX / MLX Studio that Earshot relies on, quirks included:

* ``POST /v1/audio/transcriptions`` has vMLX's FastAPI signature, so ``model`` and
  ``language`` are read from the *query string*; the multipart form fields are ignored.
* With ``--gateway`` requests are also routed by the body's ``model`` field the way
  MLX Studio's gateway (port 8080) does, answering ``404 model_not_found`` for names
  that are not loaded sessions.
* A TranslateGemma model rejects plain-string chat content with HTTP 500, like its
  real chat template does, but accepts raw prompts on ``/v1/completions``.
* Chat models "think" (``<think>…</think>``) unless ``enable_thinking`` is false.

Usage:
    python3 -m venv .venv && .venv/bin/pip install fastapi uvicorn python-multipart
    .venv/bin/python Tools/fake_mlx_studio.py --port 8080 --gateway

``GET /_log`` returns every request the server saw (handy in tests).
"""

import argparse
import asyncio
import io
import json
import re
import wave
from array import array

import uvicorn
from fastapi import FastAPI, Request, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse, StreamingResponse

PHRASES = [
    "Hola a todos, bienvenidos.",
    "Hoy vamos a hablar de traducción en tiempo real.",
    "¿Me escuchan bien al fondo de la sala?",
    "Todo funciona en el Mac, sin conexión a internet.",
    "Muchas gracias por su atención.",
]

app = FastAPI()
ARGS = argparse.Namespace(gateway=False, models=[], delay=0.02, no_completions=False, speech_language="es")
LOG: list[dict] = []
COUNTER = {"transcriptions": 0}


def model_not_found(name):
    return JSONResponse(
        status_code=404,
        content={
            "error": {
                "message": f"Model '{name or 'unknown'}' not found. Available: [{', '.join(ARGS.models)}]",
                "type": "invalid_request_error",
                "code": "model_not_found",
            }
        },
    )


def routes(name):
    """MLX Studio's gateway: exact name, else the only session."""
    return name in ARGS.models or len(ARGS.models) == 1


def wav_duration(content: bytes) -> float:
    with wave.open(io.BytesIO(content)) as handle:
        frames = handle.getnframes()
        rate = handle.getframerate()
        samples = array("h", handle.readframes(frames))
    return len(samples) / float(rate or 1)


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/v1/models")
async def models():
    data = [{"id": name, "object": "model", "owned_by": "vmlx-engine"} for name in ARGS.models]
    return {"object": "list", "data": data, "models": data}


@app.get("/_log")
async def log():
    return LOG


@app.post("/v1/audio/transcriptions")
async def create_transcription(
    request: Request,
    file: UploadFile,
    model: str = "whisper-large-v3",
    language: str | None = None,
    response_format: str = "json",
):
    form = await request.form()
    routed_by = form.get("model")
    if ARGS.gateway and not routes(routed_by):
        LOG.append({"endpoint": "transcriptions", "status": 404, "form_model": routed_by, "query_model": model})
        return model_not_found(routed_by)
    content = await file.read()
    duration = wav_duration(content)
    index = COUNTER["transcriptions"]
    COUNTER["transcriptions"] += 1
    text = PHRASES[index % len(PHRASES)]
    LOG.append(
        {
            "endpoint": "transcriptions",
            "status": 200,
            "form_model": routed_by,
            "query_model": model,
            "language": language,
            "duration": round(duration, 2),
            "filename": file.filename,
        }
    )
    if response_format == "text":
        return PlainTextResponse(text)
    return {"text": " " + text, "language": language or ARGS.speech_language, "duration": duration}


async def stream(reply: str, kind: str):
    for piece in re.findall(r"\S+\s*|\s+", reply):
        await asyncio.sleep(ARGS.delay)
        if kind == "chat":
            chunk = {"object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {"content": piece}}]}
        else:
            chunk = {"object": "text_completion", "choices": [{"index": 0, "text": piece}]}
        yield f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n"
    yield "data: [DONE]\n\n"


def apply_stops(text: str, stops) -> str:
    for stop in stops or []:
        if stop in text:
            text = text[: text.index(stop)]
    return text


@app.post("/v1/chat/completions")
async def chat(request: Request):
    body = await request.json()
    model = body.get("model", "")
    if ARGS.gateway and not routes(model):
        return model_not_found(model)
    messages = body.get("messages", [])
    content = messages[-1].get("content") if messages else ""
    entry = {"endpoint": "chat", "model": model, "enable_thinking": body.get("enable_thinking"), "turns": len(messages)}
    if "translategemma" in model.lower():
        if not isinstance(content, list) or len(content) != 1:
            LOG.append({**entry, "status": 500})
            return JSONResponse(
                status_code=500,
                content={"detail": "User role must provide content as an iterable with exactly one item."},
            )
        part = content[0]
        reply = f"[{part.get('target_lang_code')}] {part.get('text')}"
    else:
        system = next((m.get("content", "") for m in messages if m.get("role") == "system"), "")
        match = re.search(r"into ([^.]+)\.", system)
        reply = f"({match.group(1) if match else '?'}) {content}"
        if body.get("enable_thinking") is not False:
            reply = "<think>Let me think about this translation.</think>" + reply
    LOG.append({**entry, "status": 200})
    if body.get("stream"):
        return StreamingResponse(stream(reply, "chat"), media_type="text/event-stream")
    return {"choices": [{"index": 0, "message": {"role": "assistant", "content": reply}}]}


@app.post("/v1/completions")
async def completions(request: Request):
    if ARGS.no_completions:
        return JSONResponse(status_code=404, content={"detail": "Not Found"})
    body = await request.json()
    model = body.get("model", "")
    if ARGS.gateway and not routes(model):
        return model_not_found(model)
    prompt = body.get("prompt", "")
    match = re.search(r"into ([^:]+):\n\n\n(.*)<end_of_turn>", prompt, re.S)
    reply = f"[{match.group(1)}] {match.group(2)}" if match else "(unrecognised prompt)"
    # A model that is not stopped carries on past its turn.
    reply = apply_stops(reply + "<end_of_turn>\n<start_of_turn>user\nand more", body.get("stop"))
    LOG.append({"endpoint": "completions", "model": model, "status": 200, "stop": body.get("stop")})
    if body.get("stream"):
        return StreamingResponse(stream(reply, "completion"), media_type="text/event-stream")
    return {"choices": [{"index": 0, "text": reply}]}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--gateway", action="store_true", help="route by the body's model field like MLX Studio's gateway")
    parser.add_argument("--models", default="translategemma-12b-it-4bit,Qwen3-8B-4bit", help="comma-separated loaded models")
    parser.add_argument("--delay", type=float, default=0.02, help="seconds between streamed tokens")
    parser.add_argument("--no-completions", action="store_true", help="answer 404 on /v1/completions")
    parser.add_argument("--speech-language", default="es", help="language reported when none is requested")
    args = parser.parse_args()
    args.models = [name.strip() for name in args.models.split(",") if name.strip()]
    ARGS.__dict__.update(vars(args))
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()

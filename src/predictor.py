"""
eva predictor — calls DeepSeek API to predict the next shell command.
Uses the OpenAI-compatible chat completions endpoint.
"""

import os
import json
import logging
from openai import OpenAI

log = logging.getLogger("eva.predictor")

# --- Config ---
API_KEY = os.environ.get("EVA_API_KEY", "sk-b3d18f6fd0b348fd80b19aaa3754b856")
API_BASE = os.environ.get("EVA_API_BASE", "https://api.deepseek.com/v1")
MODEL = os.environ.get("EVA_MODEL", "deepseek-chat")
MAX_HISTORY = int(os.environ.get("EVA_MAX_HISTORY", "10"))

SYSTEM_PROMPT = """You are a Linux shell command autocomplete predictor.

Your task: given the user's partially typed command, working directory, and recent shell history, predict the MOST LIKELY completion of their current input.

Rules:
- Return ONLY the completion suffix (the part that comes after what the user already typed). Do NOT repeat the existing input.
- If the input is empty, suggest the most likely next command based on history and context.
- Be practical and concise — prefer common command patterns over exotic ones.
- If the user is typing a git command, consider the repo structure hints from history.
- If you're unsure, return an empty string.
- Never include explanations, markdown, or code blocks in your output.
- Maximum completion length: 100 characters."""

client = OpenAI(api_key=API_KEY, base_url=API_BASE)


def predict(buffer: str, cwd: str = "/", history: list[str] | None = None) -> str:
    """
    Predict the completion of the current shell input.

    Args:
        buffer: Current text in the shell input line
        cwd: Current working directory
        history: Recent command history (last N commands, newest first or last)

    Returns:
        Predicted completion string, or empty string if no good prediction
    """
    if history is None:
        history = []

    # Build context message
    recent = history[-MAX_HISTORY:] if len(history) > MAX_HISTORY else history
    history_str = "\n".join(f"  $ {cmd}" for cmd in recent) if recent else "  (no history)"

    user_message = f"""Current directory: {cwd}
Current input: {buffer}

Recent commands:
{history_str}

Predict the completion for the current input. Return ONLY the suffix to append."""

    try:
        response = client.chat.completions.create(
            model=MODEL,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_message},
            ],
            max_tokens=50,
            temperature=0.1,  # low temperature for consistent predictions
            stream=False,
        )

        completion = response.choices[0].message.content
        if completion is None:
            return ""

        # Clean up: strip whitespace, remove markdown artifacts
        completion = completion.strip()
        completion = completion.strip("`").strip("'").strip('"')

        # If the model returned the full command instead of just the suffix,
        # extract only the part after the buffer
        if completion.startswith(buffer) and len(completion) > len(buffer):
            completion = completion[len(buffer):]

        # Sanity check: don't return multi-line completions
        completion = completion.split("\n")[0]

        log.debug("prediction for %r -> %r", buffer, completion)
        return completion

    except Exception as e:
        log.error("API call failed: %s", e)
        return ""


# Standalone test
if __name__ == "__main__":
    logging.basicConfig(level=logging.DEBUG)
    result = predict("git com", "/home/user/dev", [
        "git status",
        "git add -A",
        "git commit -m 'fix bug'",
        "git push origin main",
        "ls -la",
    ])
    print(f"Prediction: {result!r}")

"""Run the original C engine/config with additional request retirement routes."""
from __future__ import annotations

import os
from pathlib import Path
import sys


def main():
    root = Path(os.environ["VOICE_SHARED_API_ROOT"]).resolve(strict=True)
    from nari_qwen3_tts.api import app as api
    from nari_qwen3_tts.api.schemas import SpeechRequestBody
    from nari_stop_ack import NariAckConfig, install_nari_stop_ack
    from shared_service import SharedReceipts
    from model_languages import configured_languages, LANGUAGE_NAMES
    original = api.create_app

    def create_app(engine, **kwargs):
        app = original(engine, **kwargs)
        model_id = kwargs["model_id"]
        install_nari_stop_ack(app, engine,
            parse_request=lambda body: SpeechRequestBody.model_validate(body).to_domain(served_model_id=model_id),
            config=NariAckConfig(enabled=True, isolation="shared_service",
                token=(root / "nari-token").read_text().strip(), max_text_characters=120,
                max_new_tokens=512, receipts=SharedReceipts(root),
                shared_languages=tuple(LANGUAGE_NAMES[code] for code in configured_languages())))
        # Consumer ACK is a separate contract over the same existing engine.
        from consumer_nari_ack import install_consumer_stop_ack
        install_consumer_stop_ack(app, engine,
            parse_request=lambda body: SpeechRequestBody.model_validate(body).to_domain(served_model_id=model_id),
            token=(root / "nari-token").read_text().strip())
        return app

    api.create_app = create_app
    from nari_qwen3_tts import serve
    serve.main()  # Original arguments, readiness, profiles, weights and routes.


if __name__ == "__main__":
    main()

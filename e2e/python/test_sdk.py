import os

from typesafe_sdk import Choice, Noul, Score, TypeSafeClient

BASE_URL = os.environ.get("TYPESAFE_BASE_URL", "http://0.0.0.0:5380")
API_KEY = os.environ.get("TYPESAFE_API_KEY", "local-dev-key")
EXPECTED_MODEL = os.environ.get("TYPESAFE_EXPECTED_MODEL", "winzling-jev-a8m-mock")


def assert_probability(value: float) -> None:
    assert 0.0 <= value <= 1.0


def main() -> None:
    # Mirrors the public TypeSafe Python quick-start request against our local endpoint.
    ticket = (
        "Hi, I've been trying to connect my Stripe account for 3 days and it keeps failing. "
        "I'm losing sales. Please help ASAP."
    )
    with TypeSafeClient(api_key=API_KEY, base_url=BASE_URL) as client:
        response = client.system_one(
            state=ticket,
            questions={
                "department": Choice(
                    instructions="Which team should handle this",
                    criteria={
                        "billing": "Payment or subscription issues",
                        "technical": "Bugs or integration problems",
                        "sales": "Pricing or account questions",
                    },
                ),
                "frustration": Score(
                    instructions="How frustrated the customer appears",
                    criteria=[
                        "Calm, just stating facts",
                        "Frustrated but civil",
                        "Very angry, strong language",
                    ],
                ),
                "is_urgent": Noul(
                    instructions="The message conveys urgency or time-sensitivity",
                ),
            },
        )

        assert response.model == EXPECTED_MODEL, response.model
        assert response.choices["department"].choice in {"billing", "technical", "sales"}
        assert_probability(response.choices["department"].confidence)
        assert abs(sum(response.choices["department"].probabilities.values()) - 1.0) < 1e-9
        assert 0.0 <= response.scores["frustration"].score <= 2.0
        assert_probability(response.scores["frustration"].confidence)
        assert abs(sum(response.scores["frustration"].probabilities.values()) - 1.0) < 1e-9
        assert_probability(response.nouls["is_urgent"].noul)
        assert response.usage.input_tokens > 0
        assert response.usage.output_tokens == 0

        models = client.models.list()
        names = {model.name for model in models.models}
        assert {"jev-latest", "jev-preview", "winzling-jev-a8m"} <= names

    print("Python SDK 0.7.0 compatibility: OK")


if __name__ == "__main__":
    main()

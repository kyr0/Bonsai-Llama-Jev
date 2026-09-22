import assert from "node:assert/strict";
import { choice, noul, score, TypeSafeClient } from "@typesafe-ai/sdk";

const baseURL = process.env.TYPESAFE_BASE_URL ?? "http://0.0.0.0:5380";
const apiKey = process.env.TYPESAFE_API_KEY ?? "local-dev-key";
const expectedModel = process.env.TYPESAFE_EXPECTED_MODEL ?? "winzling-jev-a8m-mock";
const client = new TypeSafeClient({ apiKey, baseURL });

// Mirrors the public TypeSafe JavaScript quick-start shape against our local endpoint.
const response = await client.systemOne({
  state: { document: "I was charged twice. Please fix this ASAP." },
  questions: {
    billing: noul("Is this ticket about billing?"),
    tone: choice("What is the customer's tone?", {
      calm: null,
      frustrated: null,
      angry: null,
    }),
    urgency: score("How urgent is this ticket?", ["can wait", "this week", "today"]),
  },
});

assert.equal(response.model, expectedModel);
assert.ok(response.answers.billing.noul >= 0 && response.answers.billing.noul <= 1);
assert.ok(["calm", "frustrated", "angry"].includes(response.answers.tone.choice));
assert.ok(response.answers.urgency.score >= 0 && response.answers.urgency.score <= 2);

const models = await client.models.list();
assert.ok(models.some((model) => model.name === "jev-latest"));

console.log("JavaScript SDK 0.6.0 compatibility: OK");

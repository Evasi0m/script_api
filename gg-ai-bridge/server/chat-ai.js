const CHAT_SYSTEM = `You are a GameGuardian assistant.
Return ONE JSON object only.

For chat/explain requests:
{ "action": "explain", "message": "short Thai explanation" }

For control requests translate to command:
{
  "action": "command",
  "type": "set_value|freeze|unfreeze|read_value|test_value",
  "target": "finding_id",
  "payload": { "value": 999, "freeze": true }
}

Never invent offsets. Use provided findings only.`;

async function callOpenAI({ apiKey, model, messages }) {
  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: model || "gpt-4o-mini",
      temperature: 0.2,
      response_format: { type: "json_object" },
      messages,
    }),
  });
  const body = await response.json();
  if (!response.ok) {
    throw new Error(body.error?.message || "OpenAI request failed");
  }
  const content = body.choices?.[0]?.message?.content;
  if (!content) throw new Error("OpenAI empty response");
  return JSON.parse(content);
}

async function callAnthropic({ apiKey, model, messages }) {
  const system = messages.find((m) => m.role === "system")?.content || CHAT_SYSTEM;
  const userMessages = messages.filter((m) => m.role !== "system");
  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: model || "claude-3-5-haiku-latest",
      max_tokens: 700,
      temperature: 0.2,
      system,
      messages: userMessages,
    }),
  });
  const body = await response.json();
  if (!response.ok) {
    throw new Error(body.error?.message || "Anthropic request failed");
  }
  const content = body.content?.[0]?.text;
  if (!content) throw new Error("Anthropic empty response");
  const start = content.indexOf("{");
  const end = content.lastIndexOf("}");
  if (start < 0 || end < 0) throw new Error("Anthropic did not return JSON");
  return JSON.parse(content.slice(start, end + 1));
}

async function translateChatToAction({
  provider,
  apiKey,
  model,
  message,
  findings,
  sessionPrompt,
}) {
  const messages = [
    { role: "system", content: CHAT_SYSTEM },
    {
      role: "user",
      content: JSON.stringify({
        user_message: message,
        session_prompt: sessionPrompt,
        findings,
      }),
    },
  ];

  if (provider === "anthropic") {
    return callAnthropic({ apiKey, model, messages });
  }
  return callOpenAI({ apiKey, model, messages });
}

module.exports = { translateChatToAction, CHAT_SYSTEM };

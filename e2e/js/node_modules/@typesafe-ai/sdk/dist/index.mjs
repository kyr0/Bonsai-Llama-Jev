const requestIdFrom = (headers) => headers.get("x-typesafe-request-id") ?? void 0;
/**
* A promise for the parsed result with access to the HTTP response.
*
* Non-2xx responses reject with an `APIError`, including through `asResponse()`.
*/
var APIPromise = class APIPromise extends Promise {
	#responsePromise;
	#parseResponse;
	#parsed;
	constructor(responsePromise, parseResponse) {
		super((resolve) => resolve(void 0));
		this.#responsePromise = responsePromise;
		this.#parseResponse = parseResponse;
	}
	/**
	* Resolves to the raw `Response` without parsing the body. SDK requests buffer the full
	* body under the request timeout before handoff; reading it afterwards is caller-owned.
	* The caller owns the body; don't also `await` the parsed result on the same promise.
	*/
	asResponse() {
		return this.#responsePromise;
	}
	/** Return the parsed result, HTTP response, and request ID. */
	async withResponse() {
		const [data, response] = await Promise.all([this.#parse(), this.#responsePromise]);
		return {
			data,
			response,
			requestId: requestIdFrom(response.headers)
		};
	}
	/** Transform the parsed result, sharing the HTTP response and a single body parse. */
	map(fn) {
		return new APIPromise(this.#responsePromise, () => this.#parse().then(fn));
	}
	#parse() {
		this.#parsed ??= this.#responsePromise.then(this.#parseResponse);
		return this.#parsed;
	}
	then(onfulfilled, onrejected) {
		return this.#parse().then(onfulfilled, onrejected);
	}
	catch(onrejected) {
		return this.#parse().catch(onrejected);
	}
	finally(onfinally) {
		return this.#parse().finally(onfinally);
	}
};
//#endregion
//#region src/env.ts
/** Environment variable names for client configuration. Explicit options take precedence. */
const ENV = {
	/** Required API key; used when `apiKey` is omitted. */
	apiKey: "TYPESAFE_API_KEY",
	/** API root; defaults to `https://api.typesafe.ai`. */
	baseURL: "TYPESAFE_BASE_URL",
	/** Default model name; defaults to `jev-latest`. */
	defaultModel: "TYPESAFE_DEFAULT_MODEL",
	/** Log level; defaults to `warn`. */
	logLevel: "TYPESAFE_LOG_LEVEL"
};
/** Read a trimmed environment value, returning `undefined` for missing or blank values. */
const readEnv = (name) => {
	if (typeof process === "undefined" || !process.env) return void 0;
	return process.env[name]?.trim() || void 0;
};
/** Return the explicit value, falling back to the environment. */
const fromCodeOrEnv = (fromCode, envVar) => fromCode ?? readEnv(envVar);
const range = (from, to) => Array.from({ length: to - from }, (_, i) => from + i);
/** Default SDK retry policy. */
const DEFAULT_RETRY_POLICY = {
	maxRetries: 2,
	backoffInitialMs: 500,
	backoffMaxMs: 5e3,
	backoffJitter: .25,
	/** HTTP 408, 429, and 5xx responses. */
	httpStatuses: /* @__PURE__ */ new Set([
		408,
		429,
		...range(500, 600)
	]),
	respectRetryAfter: true,
	/** Maximum server retry delay before falling back to backoff. */
	maxRetryAfterMs: 6e4,
	apiConnectionError: true,
	apiTimeoutError: true
};
DEFAULT_RETRY_POLICY.maxRetries;
/** Whether the policy retries an HTTP status code. */
const isRetryableStatus = (status, policy = DEFAULT_RETRY_POLICY) => policy.httpStatuses.has(status);
/**
* Parse `retry-after-ms` or `Retry-After` into milliseconds, preferring `retry-after-ms`.
*
* Return `undefined` when neither header contains a valid delay.
*/
const parseRetryAfter = (headers, now = Date.now()) => {
	const ms = Number(headers.get("retry-after-ms"));
	if (headers.has("retry-after-ms") && Number.isFinite(ms) && ms >= 0) return ms;
	const raw = headers.get("retry-after");
	if (raw === null) return void 0;
	const seconds = Number(raw);
	if (Number.isFinite(seconds)) return seconds >= 0 ? seconds * 1e3 : void 0;
	const date = Date.parse(raw);
	if (!Number.isNaN(date)) return Math.max(0, date - now);
};
/**
* Calculate the delay in milliseconds for a zero-based retry attempt.
*
* Use an allowed server delay; otherwise use capped exponential backoff with jitter.
*/
const retryDelayMs = (attempt, headers, policy = DEFAULT_RETRY_POLICY, random = Math.random) => {
	if (policy.respectRetryAfter && headers !== void 0) {
		const retryAfter = parseRetryAfter(headers);
		if (retryAfter !== void 0 && retryAfter <= policy.maxRetryAfterMs) return retryAfter;
	}
	const exponential = Math.min(policy.backoffInitialMs * 2 ** attempt, policy.backoffMaxMs);
	return Math.round(exponential * (1 - random() * policy.backoffJitter));
};
/** Wait `ms` milliseconds, rejecting with `signal.reason` on cancellation. */
const sleep = (ms, signal) => new Promise((resolve, reject) => {
	if (signal?.aborted) return reject(signal.reason);
	const onAbort = () => {
		clearTimeout(timer);
		reject(signal?.reason);
	};
	const timer = setTimeout(() => {
		signal?.removeEventListener("abort", onAbort);
		resolve();
	}, ms);
	signal?.addEventListener("abort", onAbort, { once: true });
});
//#endregion
//#region src/errors.ts
/** Base class for SDK errors. */
var TypeSafeError = class extends Error {
	constructor(message, options) {
		super(message, options);
		this.name = new.target.name;
	}
};
const isRecord = (value) => typeof value === "object" && value !== null;
/** Extract a message from a text, error, or validation response body. */
const extractMessage = (body) => {
	if (typeof body === "string") return body || void 0;
	if (!isRecord(body)) return void 0;
	const { error, message, detail } = body;
	if (typeof error === "string") return error;
	if (isRecord(error) && typeof error.message === "string") return error.message;
	if (typeof message === "string") return message;
	if (typeof detail === "string") return detail;
	if (isRecord(detail) && typeof detail.message === "string") return detail.message;
	if (Array.isArray(detail)) return describeValidationErrors(detail);
};
/** Format validation errors as semicolon-separated `path: message` entries. */
const describeValidationErrors = (errors) => {
	const parts = errors.flatMap((e) => {
		if (!isRecord(e) || typeof e.msg !== "string") return [];
		const loc = Array.isArray(e.loc) ? e.loc.filter((x) => x !== "body").join(".") : "";
		return [loc ? `${loc}: ${e.msg}` : e.msg];
	});
	return parts.length > 0 ? parts.join("; ") : void 0;
};
const MAX_RAW_BODY_IN_MESSAGE = 200;
/** An unsuccessful HTTP response from the API. */
var APIError = class APIError extends TypeSafeError {
	/** HTTP response status code. */
	status;
	/** HTTP response headers. */
	headers;
	/** Parsed JSON, response text, or `undefined` for an empty body. */
	body;
	/** Request ID from `x-typesafe-request-id`, or `undefined` when absent. */
	requestId;
	constructor(status, body, headers, message) {
		super(message ?? APIError.describe(status, body));
		this.status = status;
		this.body = body;
		this.headers = headers;
		this.requestId = requestIdFrom(headers);
	}
	static describe(status, body) {
		const detail = extractMessage(body);
		if (detail) return `${status} ${detail}`;
		if (body === void 0) return `${status} status code (no body)`;
		const raw = typeof body === "string" ? body : JSON.stringify(body);
		return `${status} ${raw.length > MAX_RAW_BODY_IN_MESSAGE ? `${raw.slice(0, MAX_RAW_BODY_IN_MESSAGE)}…` : raw}`;
	}
	/** Create the error subclass for an HTTP status code. */
	static fromResponse(status, body, headers) {
		if (status === 400) return new BadRequestError(status, body, headers);
		if (status === 401) return new AuthenticationError(status, body, headers);
		if (status === 403) return new PermissionDeniedError(status, body, headers);
		if (status === 404) return new NotFoundError(status, body, headers);
		if (status === 422) return new UnprocessableEntityError(status, body, headers);
		if (status === 429) return new RateLimitError(status, body, headers);
		if (status >= 500) return new InternalServerError(status, body, headers);
		return new APIError(status, body, headers);
	}
};
/** HTTP 400: the request is invalid. */
var BadRequestError = class extends APIError {};
/** HTTP 401: authentication failed. */
var AuthenticationError = class extends APIError {};
/** HTTP 403: access is denied. */
var PermissionDeniedError = class extends APIError {};
/** HTTP 404: the resource was not found. */
var NotFoundError = class extends APIError {};
/** HTTP 422: request validation failed. */
var UnprocessableEntityError = class extends APIError {};
/** HTTP 429: the rate limit was exceeded. */
var RateLimitError = class extends APIError {
	/** Server retry delay in milliseconds, or `undefined` when absent or invalid. */
	retryAfterMs = parseRetryAfter(this.headers);
};
/** HTTP 5xx: the server failed to handle the request. */
var InternalServerError = class extends APIError {};
/** The request or response-body delivery failed (DNS, TLS, connection closed, etc.). */
var APIConnectionError = class extends TypeSafeError {
	constructor(message = "Connection error.", options) {
		super(message, options);
	}
};
/** The full response did not arrive within the timeout. A kind of `APIConnectionError`. */
var APITimeoutError = class extends APIConnectionError {
	/** Configured timeout in milliseconds. */
	timeoutMs;
	constructor(timeoutMs, options) {
		super(`Request timed out after ${timeoutMs}ms.`, options);
		this.timeoutMs = timeoutMs;
	}
};
/** The caller cancelled the request through an `AbortSignal`. */
var APIUserAbortError = class extends TypeSafeError {
	constructor(message = "Request was aborted.", options) {
		super(message, options);
	}
};
//#endregion
//#region src/logging.ts
/** Supported log levels, from most to least verbose. */
const LOG_LEVELS = [
	"debug",
	"info",
	"warn",
	"error",
	"off"
];
const DEFAULT_LOG_LEVEL = "warn";
const isLogLevel = (value) => LOG_LEVELS.includes(value);
/** Validate a configured log level, throwing `TypeSafeError` for unknown values. */
const parseLogLevel = (value, source) => {
	if (isLogLevel(value)) return value;
	throw new TypeSafeError(`Invalid log level "${value}" from ${source}. Expected one of: ${LOG_LEVELS.join(", ")}.`);
};
const PREFIX = "[typesafe-sdk]";
/** Default console logger with the `[typesafe-sdk]` prefix. */
const consoleLogger = {
	debug: (message, ...args) => console.debug(`${PREFIX} ${message}`, ...args),
	info: (message, ...args) => console.info(`${PREFIX} ${message}`, ...args),
	warn: (message, ...args) => console.warn(`${PREFIX} ${message}`, ...args),
	error: (message, ...args) => console.error(`${PREFIX} ${message}`, ...args)
};
const RANK = {
	debug: 0,
	info: 1,
	warn: 2,
	error: 3,
	off: 4
};
const drop = () => {};
/** Filter logger calls to the configured level and above. */
const withLevel = (sink, level) => {
	const enabled = (at) => RANK[at] >= RANK[level];
	return {
		debug: enabled("debug") ? (message, ...args) => sink.debug(message, ...args) : drop,
		info: enabled("info") ? (message, ...args) => sink.info(message, ...args) : drop,
		warn: enabled("warn") ? (message, ...args) => sink.warn(message, ...args) : drop,
		error: enabled("error") ? (message, ...args) => sink.error(message, ...args) : drop
	};
};
/** Credential headers that retain a key suffix for identification. */
const KEY_HEADERS = /* @__PURE__ */ new Set([
	"authorization",
	"proxy-authorization",
	"x-api-key"
]);
/** Headers whose values are redacted in full. */
const OPAQUE_HEADERS = /* @__PURE__ */ new Set(["cookie", "set-cookie"]);
/** Mask a key, preserving its scheme and the last four characters of secrets longer than eight. */
const redactKey = (value) => {
	const [scheme, secret] = value.includes(" ") ? value.split(/\s+/, 2) : [void 0, value];
	const tail = secret && secret.length > 8 ? secret.slice(-4) : "";
	return `${scheme ? `${scheme} ` : ""}***${tail}`;
};
const redact = (name, value) => {
	const lower = name.toLowerCase();
	if (KEY_HEADERS.has(lower)) return redactKey(value);
	if (OPAQUE_HEADERS.has(lower)) return "***";
	return value;
};
/** Copy headers with known credential values redacted. */
const redactHeaders = (headers) => Object.fromEntries(Object.entries(headers).map(([name, value]) => [name, redact(name, value)]));
//#endregion
//#region src/questions.ts
/**
* Create a yes/no question with optional descriptions for either outcome.
*
* @param instructions - The question as text, a JSON object or array; defaults to `null`.
* @param criteria - Optional descriptions of the yes and no outcomes.
*/
const noul = (instructions = null, criteria) => ({
	type: "noul",
	instructions,
	criteria
});
/**
* Create a score question using an ordered rubric.
*
* @param instructions - The question as text, a JSON object or array, or `null`.
* @param criteria - At least two descriptions indexed by score from zero; entries may be `null`.
*/
const score = (instructions, criteria) => {
	if (!Array.isArray(criteria)) throw new TypeSafeError("Score criteria must be a list of descriptions indexed by score from zero, not a map.");
	return {
		type: "score",
		instructions,
		criteria
	};
};
/**
* Create a question that selects between named alternatives.
*
* @param instructions - The question as text, a JSON object or array, or `null`.
* @param criteria - Labels mapped to descriptions, or `null` for undescribed labels.
*/
const choice = (instructions, criteria) => {
	if (Array.isArray(criteria)) throw new TypeSafeError("Choice criteria must be a map of labels to descriptions, not a list.");
	return {
		type: "choice",
		instructions,
		criteria
	};
};
/** Reject empty question sets and score questions without a list of at least two criteria. */
const validateQuestions = (questions) => {
	if (Object.keys(questions).length === 0) throw new TypeSafeError("At least one question is required.");
	for (const [name, question] of Object.entries(questions)) {
		if (question.type !== "score") continue;
		if (!Array.isArray(question.criteria)) throw new TypeSafeError(`Score question "${name}" has criteria that are not a list; score criteria must be a list of descriptions indexed by score from zero.`);
		if (question.criteria.length < 2) throw new TypeSafeError(`Score question "${name}" has ${question.criteria.length} criteria; at least two scores are required.`);
	}
};
//#endregion
//#region src/resources/models.ts
/** Access to the Models API resource. */
var Models = class {
	#transport;
	constructor(transport) {
		this.#transport = transport;
	}
	/** List the models available to the account. */
	list(options = {}) {
		return this.#transport.request("GET", "/v1/models", options).map(unwrapModels);
	}
};
const unwrapModels = (wire) => {
	if (Array.isArray(wire?.models)) return wire.models;
	throw new TypeSafeError("Unexpected response shape from GET /v1/models; expected { models: [...] }.");
};
//#endregion
//#region src/runtime.ts
const g = globalThis;
/** Whether browser page globals are present. */
const isBrowser = () => typeof g.window !== "undefined" && typeof g.window.document !== "undefined" && typeof g.navigator !== "undefined";
/** Runtime name, version, and platform for the `X-TypeSafe-Runtime` header. */
const describeRuntime = () => {
	const platform = g.process?.platform && g.process?.arch ? ` (${g.process.platform}; ${g.process.arch})` : "";
	if (g.Bun?.version) return `bun/${g.Bun.version}${platform}`;
	if (g.Deno?.version?.deno) return `deno/${g.Deno.version.deno}${platform}`;
	if (g.EdgeRuntime !== void 0) return "vercel-edge";
	if (g.navigator?.userAgent === "Cloudflare-Workers") return "cloudflare-workers";
	if (g.process?.versions?.node) return `node/${g.process.versions.node}${platform}`;
	if (isBrowser()) return "browser";
	return "unknown";
};
//#endregion
//#region src/version.ts
const VERSION = "0.6.0";
const missingApiKey = () => {
	throw new TypeSafeError(`No API key was provided. Pass \`apiKey\` to the TypeSafeClient constructor or set the ${ENV.apiKey} environment variable.`);
};
const missingFetch = () => {
	throw new TypeSafeError("No global `fetch` is available in this runtime. Pass a `fetch` implementation to the TypeSafeClient constructor.");
};
const refuseBrowser = () => {
	throw new TypeSafeError("TypeSafeClient is running in a browser, which would expose your API key to anyone using the page. Call the API from a server instead, or pass `dangerouslyAllowBrowser: true` if you understand the risk.");
};
/** Call global `fetch` with its required receiver in browsers. */
const defaultFetch = (input, init) => globalThis.fetch(input, init);
const assertNonNegativeInteger = (name, value) => {
	if (!Number.isInteger(value) || value < 0) throw new TypeSafeError(`\`${name}\` must be a non-negative integer, got ${String(value)}.`);
	return value;
};
const assertPositiveMs = (name, value) => {
	if (!Number.isFinite(value) || value <= 0) throw new TypeSafeError(`\`${name}\` must be a positive number of milliseconds, got ${String(value)}.`);
	return value;
};
const assertNonNegativeMs = (name, value) => {
	if (!Number.isFinite(value) || value < 0) throw new TypeSafeError(`\`${name}\` must be a non-negative number of milliseconds, got ${String(value)}.`);
	return value;
};
const assertFraction = (name, value) => {
	if (!Number.isFinite(value) || value < 0 || value > 1) throw new TypeSafeError(`\`${name}\` must be between 0 and 1, got ${String(value)}.`);
	return value;
};
const assertStatusSet = (name, statuses) => {
	for (const status of statuses) if (!Number.isInteger(status) || status < 100 || status > 999) throw new TypeSafeError(`\`${name}\` must contain HTTP status codes, got ${String(status)}.`);
	return statuses;
};
/** Merge and validate retry overrides, copying the status set to isolate later mutations. */
const resolveRetryPolicy = (base, overrides) => {
	const o = overrides ?? {};
	return {
		maxRetries: o.maxRetries === void 0 ? base.maxRetries : assertNonNegativeInteger("retry.maxRetries", o.maxRetries),
		backoffInitialMs: o.backoffInitialMs === void 0 ? base.backoffInitialMs : assertNonNegativeMs("retry.backoffInitialMs", o.backoffInitialMs),
		backoffMaxMs: o.backoffMaxMs === void 0 ? base.backoffMaxMs : assertNonNegativeMs("retry.backoffMaxMs", o.backoffMaxMs),
		backoffJitter: o.backoffJitter === void 0 ? base.backoffJitter : assertFraction("retry.backoffJitter", o.backoffJitter),
		httpStatuses: new Set(o.httpStatuses === void 0 ? base.httpStatuses : assertStatusSet("retry.httpStatuses", o.httpStatuses)),
		respectRetryAfter: o.respectRetryAfter ?? base.respectRetryAfter,
		maxRetryAfterMs: o.maxRetryAfterMs === void 0 ? base.maxRetryAfterMs : assertNonNegativeMs("retry.maxRetryAfterMs", o.maxRetryAfterMs),
		apiConnectionError: o.apiConnectionError ?? base.apiConnectionError,
		apiTimeoutError: o.apiTimeoutError ?? base.apiTimeoutError
	};
};
/** Whether the policy retries a connection error or timeout. */
const isRetryableError = (err, policy) => {
	if (err instanceof APITimeoutError) return policy.apiTimeoutError;
	if (err instanceof APIConnectionError) return policy.apiConnectionError;
	return false;
};
/** Resolve and validate the log level from configuration or the environment. */
const resolveLogLevel = (fromCode) => {
	if (fromCode !== void 0) return parseLogLevel(fromCode, "the `logLevel` option");
	const fromEnv = readEnv(ENV.logLevel);
	if (fromEnv !== void 0) return parseLogLevel(fromEnv, ENV.logLevel);
	return DEFAULT_LOG_LEVEL;
};
const stripTrailingSlashes = (url) => url.replace(/\/+$/, "");
/** Last value wins regardless of casing; undefined removes a protected header. */
const mergeHeaders = (...sources) => {
	const entries = /* @__PURE__ */ new Map();
	for (const source of sources) for (const [name, value] of Object.entries(source)) if (value === void 0) entries.delete(name.toLowerCase());
	else entries.set(name.toLowerCase(), [name, value]);
	return Object.fromEntries(entries.values());
};
/** Drain a clone so the original response retains its metadata and a readable, buffered body. */
const bufferResponse = async (response, signal) => {
	const reader = response.clone().body?.getReader();
	if (!reader) return;
	const cancel = () => {
		reader.cancel(signal.reason).catch(() => {});
		response.body?.cancel(signal.reason).catch(() => {});
	};
	signal.addEventListener("abort", cancel, { once: true });
	try {
		if (signal.aborted) cancel();
		signal.throwIfAborted();
		while (!(await reader.read()).done) signal.throwIfAborted();
		signal.throwIfAborted();
	} finally {
		signal.removeEventListener("abort", cancel);
		reader.releaseLock();
	}
};
/** Runtime description cached for the process lifetime. */
const RUNTIME = describeRuntime();
/** Client for the TypeSafe AI API. */
var TypeSafeClient = class {
	/** API key excluded from serialization and public properties. */
	#apiKey;
	/** API root with trailing slashes removed. */
	baseURL;
	/** Model used when a request omits `model`. */
	defaultModel;
	/** Configured log verbosity. */
	logLevel;
	/** The configured logger, filtered to `logLevel`. */
	logger;
	/** Retry settings with constructor overrides applied. */
	retry;
	/** Timeout per attempt in milliseconds. */
	timeout;
	/** Additional headers sent with each request. */
	defaultHeaders;
	/** HTTP fetch implementation. */
	fetch;
	/** The models available to the account. */
	models;
	#requestCount = 0;
	/**
	* Create a client for the TypeSafe AI API.
	*
	* Explicit options take precedence over environment variables, then SDK defaults.
	* Empty or whitespace-only environment values are ignored.
	*
	* @throws {TypeSafeError} The API key is missing, configuration is invalid, or the runtime is unsupported.
	*/
	constructor(config = {}) {
		if (isBrowser() && !config.dangerouslyAllowBrowser) refuseBrowser();
		this.#apiKey = fromCodeOrEnv(config.apiKey, ENV.apiKey) ?? missingApiKey();
		this.baseURL = stripTrailingSlashes(fromCodeOrEnv(config.baseURL, ENV.baseURL) ?? "https://api.typesafe.ai");
		this.defaultModel = fromCodeOrEnv(config.defaultModel, ENV.defaultModel) ?? "jev-latest";
		this.logLevel = resolveLogLevel(config.logLevel);
		this.logger = withLevel(config.logger ?? consoleLogger, this.logLevel);
		this.retry = resolveRetryPolicy(DEFAULT_RETRY_POLICY, config.retry);
		this.timeout = assertPositiveMs("timeout", config.timeout ?? 1e4);
		this.defaultHeaders = { ...config.defaultHeaders };
		if (config.fetch === void 0 && typeof globalThis.fetch !== "function") missingFetch();
		this.fetch = config.fetch ?? defaultFetch;
		const transport = {
			request: (method, path, options) => this.#request(method, path, options),
			defaultModel: this.defaultModel
		};
		this.models = new Models(transport);
	}
	/**
	* Answer named questions about text or structured state.
	*
	* @param request - State, questions, and an optional model override.
	* @param options - Per-call timeout, retry, headers, and cancellation settings.
	* @returns Answers typed by question name and criteria, with model and token usage.
	* @throws {TypeSafeError} Questions are empty, or score criteria are not a list of at least two entries.
	* @throws {APIError} The server returns a non-2xx response after retries.
	* @throws {APIConnectionError} The request cannot connect or times out after retries.
	* @throws {APIUserAbortError} The caller aborts the request.
	*
	* @example
	* ```ts
	* const { answers } = await client.systemOne({
	*   state: "I was charged twice. Please help.",
	*   questions: { billing: noul("Is this about billing?") },
	* });
	* console.log(answers.billing.noul);
	* ```
	*/
	systemOne(request, options = {}) {
		validateQuestions(request.questions);
		const body = {
			...request,
			model: request.model ?? this.defaultModel
		};
		return this.#request("POST", "/v1/systemone", {
			...options,
			body
		});
	}
	/** Send a request and parse its response body. */
	#request(method, path, options = {}) {
		const resolved = {
			method,
			path,
			body: options.body,
			headers: mergeHeaders(this.defaultHeaders, options.headers ?? {}),
			signal: options.signal,
			timeout: options.timeout === void 0 ? this.timeout : assertPositiveMs("timeout", options.timeout),
			retry: resolveRetryPolicy(this.retry, options.retry)
		};
		const tag = `#${++this.#requestCount} ${method} ${path}`;
		return new APIPromise(this.fetchWithRetries(tag, resolved), async (res) => {
			const parsed = await parseBody(res);
			this.logger.debug(`${tag} <- body`, parsed);
			return parsed;
		});
	}
	/** Retry eligible failures, logging attempt summaries at `info` and headers and bodies at `debug`. */
	async fetchWithRetries(tag, req) {
		const url = `${this.baseURL}${req.path}`;
		const headers = mergeHeaders(req.headers, {
			Authorization: `Bearer ${this.#apiKey}`,
			Accept: "application/json",
			"User-Agent": `typesafe-sdk/${VERSION}`,
			"X-TypeSafe-SDK": `typesafe-sdk/${VERSION}`,
			"X-TypeSafe-Runtime": RUNTIME,
			"Content-Type": req.body === void 0 ? void 0 : "application/json",
			"X-TypeSafe-Retry-Count": void 0
		});
		const body = req.body === void 0 ? void 0 : JSON.stringify(req.body);
		for (let attempt = 0;; attempt++) {
			const retriesLeft = req.retry.maxRetries - attempt;
			const attemptHeaders = attempt === 0 ? headers : {
				...headers,
				"X-TypeSafe-Retry-Count": String(attempt)
			};
			this.logger.debug(`${tag} -> ${url}`, {
				headers: redactHeaders(attemptHeaders),
				body: req.body
			});
			const started = Date.now();
			let res;
			try {
				res = await this.attempt(tag, url, {
					method: req.method,
					headers: attemptHeaders,
					body
				}, req);
			} catch (err) {
				if (err instanceof APIUserAbortError || retriesLeft <= 0) throw err;
				if (!isRetryableError(err, req.retry)) throw err;
				await this.backOff(tag, attempt, retriesLeft, err.message, void 0, req);
				continue;
			}
			const requestId = requestIdFrom(res.headers);
			this.logger.info(`${tag} <- ${res.status} in ${Date.now() - started}ms${requestId ? ` (request ${requestId})` : ""}`);
			if (res.ok) return res;
			const errorBody = await parseBody(res);
			this.logger.debug(`${tag} <- error body`, errorBody);
			const error = APIError.fromResponse(res.status, errorBody, res.headers);
			if (retriesLeft <= 0 || !isRetryableStatus(res.status, req.retry)) throw error;
			await this.backOff(tag, attempt, retriesLeft, `${res.status}`, res.headers, req);
		}
	}
	/**
	* One HTTP round trip, including body delivery, with a timeout. The caller's signal and our
	* timer both abort the same controller; we check which fired to choose the error class.
	*/
	async attempt(tag, url, init, { signal, timeout }) {
		const controller = new AbortController();
		const abortFromCaller = () => controller.abort(signal?.reason);
		if (signal?.aborted) abortFromCaller();
		signal?.addEventListener("abort", abortFromCaller, { once: true });
		let timedOut = false;
		const timer = setTimeout(() => {
			timedOut = true;
			controller.abort();
		}, timeout);
		const started = Date.now();
		const elapsed = () => `${Date.now() - started}ms`;
		try {
			const response = await this.fetch(url, {
				...init,
				signal: controller.signal
			});
			await bufferResponse(response, controller.signal);
			return response;
		} catch (err) {
			if (signal?.aborted) {
				this.logger.info(`${tag} aborted by caller after ${elapsed()}`);
				throw new APIUserAbortError(void 0, { cause: err });
			}
			if (timedOut) {
				this.logger.info(`${tag} timed out after ${elapsed()}`);
				throw new APITimeoutError(timeout, { cause: err });
			}
			this.logger.info(`${tag} connection error after ${elapsed()}`, err);
			throw new APIConnectionError(err instanceof Error ? `Connection error: ${err.message}` : void 0, { cause: err });
		} finally {
			clearTimeout(timer);
			signal?.removeEventListener("abort", abortFromCaller);
		}
	}
	/** Wait before retrying; caller cancellation throws `APIUserAbortError`. */
	async backOff(tag, attempt, retriesLeft, reason, headers, { retry, signal }) {
		const delay = retryDelayMs(attempt, headers, retry);
		const nth = attempt + 1;
		const total = attempt + retriesLeft;
		this.logger.info(`${tag} retrying in ${delay}ms (retry ${nth}/${total}) after ${reason}`);
		try {
			await sleep(delay, signal);
		} catch (err) {
			this.logger.info(`${tag} aborted by caller while waiting to retry`);
			throw new APIUserAbortError(void 0, { cause: err });
		}
	}
};
const parseBody = async (res) => {
	const text = await res.text();
	if (text.length === 0) return void 0;
	if ((res.headers.get("content-type") ?? "").includes("application/json")) try {
		return JSON.parse(text);
	} catch {
		return text;
	}
	try {
		return JSON.parse(text);
	} catch {
		return text;
	}
};
//#endregion
export { APIConnectionError, APIError, APIPromise, APITimeoutError, APIUserAbortError, AuthenticationError, BadRequestError, ENV, InternalServerError, LOG_LEVELS, NotFoundError, PermissionDeniedError, RateLimitError, TypeSafeClient, TypeSafeError, UnprocessableEntityError, VERSION, choice, noul, score };

//# sourceMappingURL=index.mjs.map
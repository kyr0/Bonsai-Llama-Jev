//#region src/api-promise.d.ts
/** Parsed data with its HTTP response and request ID. */
interface WithResponse<T> {
  /** The parsed response body. */
  data: T;
  /** The HTTP response, with its body consumed by parsing. */
  response: Response;
  /** Request ID from `x-typesafe-request-id`, or `undefined` when absent. */
  requestId: string | undefined;
}
/**
 * A promise for the parsed result with access to the HTTP response.
 *
 * Non-2xx responses reject with an `APIError`, including through `asResponse()`.
 */
declare class APIPromise<T> extends Promise<T> {
  #private;
  constructor(responsePromise: Promise<Response>, parseResponse: (response: Response) => Promise<T>);
  /**
   * Resolves to the raw `Response` without parsing the body. SDK requests buffer the full
   * body under the request timeout before handoff; reading it afterwards is caller-owned.
   * The caller owns the body; don't also `await` the parsed result on the same promise.
   */
  asResponse(): Promise<Response>;
  /** Return the parsed result, HTTP response, and request ID. */
  withResponse(): Promise<WithResponse<T>>;
  /** Transform the parsed result, sharing the HTTP response and a single body parse. */
  map<U>(fn: (data: T) => U): APIPromise<U>;
  override then<TResult1 = T, TResult2 = never>(onfulfilled?: ((value: T) => TResult1 | PromiseLike<TResult1>) | null, onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null): Promise<TResult1 | TResult2>;
  override catch<TResult = never>(onrejected?: ((reason: unknown) => TResult | PromiseLike<TResult>) | null): Promise<T | TResult>;
  override finally(onfinally?: (() => void) | null): Promise<T>;
}
//#endregion
//#region src/types.d.ts
/** A JSON-compatible value. */
type JsonValue = string | number | boolean | null | JsonValue[] | {
  [key: string]: JsonValue;
};
/** Text, a JSON object or array, or `null` for state, instructions, and criteria. */
type EntryType = string | {
  [key: string]: JsonValue;
} | JsonValue[] | null;
/** A criterion description; `null` leaves the label undescribed. */
type Description = EntryType;
/** A yes/no question with optional descriptions for either outcome. */
interface NoulQuestion {
  type: "noul";
  /** The question as text, a JSON object, or an array; optional or `null`. */
  instructions?: EntryType;
  /** Optional descriptions of the yes and no outcomes. */
  criteria?: {
    /** Description of the yes outcome. */
    true?: EntryType;
    /** Description of the no outcome. */
    false?: EntryType;
  } | null;
}
/** Labels mapped to descriptions, or `null` for undescribed labels. */
type ChoiceCriteria = {
  [label: string]: Description;
};
/** A question that selects between named alternatives. */
interface ChoiceQuestion<T extends ChoiceCriteria = ChoiceCriteria> {
  type: "choice";
  /** The question as text, a JSON object, or an array; optional or `null`. */
  instructions?: EntryType;
  /** Descriptions of the available outcomes. */
  criteria: T;
}
/** At least two descriptions indexed by score from zero; `null` leaves a score undescribed. */
type ScoreCriteria = readonly [EntryType, EntryType, ...EntryType[]];
/** A question that assigns a score using an ordered rubric. */
interface ScoreQuestion<T extends ScoreCriteria = ScoreCriteria> {
  type: "score";
  /** The question as text, a JSON object, or an array; optional or `null`. */
  instructions?: EntryType;
  /** Descriptions of the available outcomes. */
  criteria: T;
}
/** A question identified by its `type` field. */
type Question = NoulQuestion | ScoreQuestion | ChoiceQuestion;
/** Questions keyed by the names used to identify their answers. */
interface Questions {
  [name: string]: Question;
}
/** A yes/no answer. */
interface NoulResponse {
  readonly type: "noul";
  /** Probability of a yes answer, from zero to one. */
  readonly noul: number;
}
/** A selected label and its probabilities. */
interface ChoiceResponse<T extends ChoiceCriteria = ChoiceCriteria> {
  readonly type: "choice";
  /** The selected label. */
  readonly choice: keyof T & string;
  /** Reported confidence in the selected label. */
  readonly confidence: number;
  /** Probabilities keyed by label. */
  readonly probabilities: { readonly [label in keyof T]: number; };
}
/** Score keys inferred from the rubric; a fixed-length tuple yields its indices, otherwise `number`. */
type ScoreOf<T extends ScoreCriteria> = number extends T["length"] ? number : Extract<keyof T, `${number}`>;
/** Rubric descriptions keyed by score. */
type ScoreLegend<T extends ScoreCriteria> = { readonly [score in ScoreOf<T>]: T[score]; };
/** An expected score with its rubric and probabilities. */
interface ScoreResponse<T extends ScoreCriteria = ScoreCriteria> {
  readonly type: "score";
  /** Expected score, which may fall between integer rubric levels. */
  readonly score: number;
  /** Reported confidence in the score. */
  readonly confidence: number;
  /** Rubric descriptions keyed by score. */
  readonly legend: ScoreLegend<T>;
  /** Probabilities keyed by score. */
  readonly probabilities: { readonly [score in ScoreOf<T>]: number; };
}
/** The answer type for a question, preserving its criteria keys. */
type ResultFor<T extends Question> = T extends NoulQuestion ? NoulResponse : T extends ScoreQuestion<infer S> ? ScoreResponse<S> : T extends ChoiceQuestion<infer E> ? ChoiceResponse<E> : never;
/** Token usage for a request. */
interface Usage {
  /** Number of input tokens used. */
  readonly input_tokens: number;
  /** Number of output tokens used. */
  readonly output_tokens: number;
}
/** Answers keyed by question name, with model and usage metadata. */
interface SystemOneResult<Q extends Questions> {
  /** The model used to answer the request. */
  readonly model: string;
  /** Answers with types inferred from the supplied questions. */
  readonly answers: { readonly [K in keyof Q]: ResultFor<Q[K]>; };
  /** Token usage for the request. */
  readonly usage: Usage;
}
/** Metadata for an available model. */
interface ModelCard {
  readonly name: string;
  readonly description: string;
  readonly release_date: string;
}
/**
 * State and named questions for `systemOne`.
 *
 * Additional properties on a request variable are forwarded, including `null` values.
 */
interface SystemOneRequest<Q extends Questions = Questions> {
  /** Text, a JSON object or array, or `null` to evaluate. */
  state: EntryType;
  /** Nonempty questions keyed by the names used to identify their answers. */
  questions: Q;
  /** Model override; omitted values inherit `defaultModel`. */
  model?: string;
}
/** Request body for `POST /v1/systemone`, with the model resolved. */
interface SystemOneRequestPayload extends SystemOneRequest {
  model: string;
}
/** Retry configuration. Partial overrides inherit unset fields from the client or SDK defaults. */
interface RetryPolicy {
  /** Maximum retries after the initial attempt; `0` disables retries. Default: 2. */
  readonly maxRetries: number;
  /** First backoff delay in milliseconds, doubled up to `backoffMaxMs`. Default: 500. */
  readonly backoffInitialMs: number;
  /** Maximum backoff delay in milliseconds. Default: 5000. */
  readonly backoffMaxMs: number;
  /** Fraction of each backoff delay randomly subtracted, from 0 to 1. Default: 0.25. */
  readonly backoffJitter: number;
  /** HTTP status codes to retry. Default: 408, 429, and 500–599. */
  readonly httpStatuses: ReadonlySet<number>;
  /** Honor `Retry-After` and `retry-after-ms` up to `maxRetryAfterMs`. Default: true. */
  readonly respectRetryAfter: boolean;
  /** Maximum server retry delay in milliseconds; longer delays use backoff. Default: 60000. */
  readonly maxRetryAfterMs: number;
  /** Retry connection failures, including interrupted response bodies (`APIConnectionError`). Default: true. */
  readonly apiConnectionError: boolean;
  /** Whether to retry `APITimeoutError`. Default: true. */
  readonly apiTimeoutError: boolean;
}
/** Per-call options that override client settings. */
interface RequestOptions {
  /** Cancellation signal for the request and pending retries. */
  signal?: AbortSignal;
  /** Timeout per attempt in milliseconds; there is no total retry budget. */
  timeout?: number;
  /** Retry overrides for this call; omitted fields inherit client settings. */
  retry?: Partial<RetryPolicy>;
  /** Additional headers, merged over `defaultHeaders`. */
  headers?: Record<string, string>;
}
/** HTTP fetch implementation compatible with the global `fetch`. */
type Fetch = (input: string, init?: RequestInit) => Promise<Response>;
/** Log verbosity; `off` disables logging. */
type LogLevel = "debug" | "info" | "warn" | "error" | "off";
/** Log methods accepting a message and structured values; compatible with `console`. */
interface Logger {
  debug(message: string, ...args: unknown[]): void;
  info(message: string, ...args: unknown[]): void;
  warn(message: string, ...args: unknown[]): void;
  error(message: string, ...args: unknown[]): void;
}
/** Client options. Explicit values take precedence over environment variables, then SDK defaults. */
interface TypeSafeClientConfig {
  /** Required API key; falls back to `TYPESAFE_API_KEY`. */
  apiKey?: string;
  /** API root; falls back to `TYPESAFE_BASE_URL`, then `https://api.typesafe.ai`. */
  baseURL?: string;
  /** Default model; falls back to `TYPESAFE_DEFAULT_MODEL`, then `jev-latest`. */
  defaultModel?: string;
  /**
   * Log level; falls back to `TYPESAFE_LOG_LEVEL`, then `warn`.
   * `info` logs request summaries; `debug` adds headers and bodies.
   * Known credential headers are redacted; bodies are not.
   */
  logLevel?: LogLevel;
  /** Logger filtered to `logLevel` and above. Default: prefixed `console`. */
  logger?: Logger;
  /** Retry overrides; omitted fields use the defaults in `RetryPolicy`. */
  retry?: Partial<RetryPolicy>;
  /** Timeout per attempt in milliseconds, without a total retry budget. Default: 10000. */
  timeout?: number;
  /** Additional request headers; per-call headers take precedence. */
  defaultHeaders?: Record<string, string>;
  /** Allow browser use, exposing the API key to page users. Default: false. */
  dangerouslyAllowBrowser?: boolean;
  /** Custom HTTP fetch implementation for transport configuration or tests. Default: global `fetch`. */
  fetch?: Fetch;
}
//#endregion
//#region src/resources/models.d.ts
/** Access to the Models API resource. */
declare class Models {
  #private;
  constructor(transport: Transport);
  /** List the models available to the account. */
  list(options?: RequestOptions): APIPromise<ModelCard[]>;
}
//#endregion
//#region src/client.d.ts
/** Per-call transport options with an optional JSON body. */
interface RawRequestOptions extends RequestOptions {
  body?: unknown;
}
/** Internal transport interface used by API resources. */
interface Transport {
  request<T>(method: "GET" | "POST", path: string, options?: RawRequestOptions): APIPromise<T>;
  readonly defaultModel: string;
}
/** Client for the TypeSafe AI API. */
declare class TypeSafeClient {
  #private;
  /** API root with trailing slashes removed. */
  readonly baseURL: string;
  /** Model used when a request omits `model`. */
  readonly defaultModel: string;
  /** Configured log verbosity. */
  readonly logLevel: LogLevel;
  /** The configured logger, filtered to `logLevel`. */
  readonly logger: Logger;
  /** Retry settings with constructor overrides applied. */
  readonly retry: RetryPolicy;
  /** Timeout per attempt in milliseconds. */
  readonly timeout: number;
  /** Additional headers sent with each request. */
  readonly defaultHeaders: Readonly<Record<string, string>>;
  /** HTTP fetch implementation. */
  readonly fetch: Fetch;
  /** The models available to the account. */
  readonly models: Models;
  /**
   * Create a client for the TypeSafe AI API.
   *
   * Explicit options take precedence over environment variables, then SDK defaults.
   * Empty or whitespace-only environment values are ignored.
   *
   * @throws {TypeSafeError} The API key is missing, configuration is invalid, or the runtime is unsupported.
   */
  constructor(config?: TypeSafeClientConfig);
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
  systemOne<const Q extends Questions>(request: SystemOneRequest<Q>, options?: RequestOptions): APIPromise<SystemOneResult<Q>>;
  /** Retry eligible failures, logging attempt summaries at `info` and headers and bodies at `debug`. */
  private fetchWithRetries;
  /**
   * One HTTP round trip, including body delivery, with a timeout. The caller's signal and our
   * timer both abort the same controller; we check which fired to choose the error class.
   */
  private attempt;
  /** Wait before retrying; caller cancellation throws `APIUserAbortError`. */
  private backOff;
}
//#endregion
//#region src/env.d.ts
/** Environment variable names for client configuration. Explicit options take precedence. */
declare const ENV: {
  /** Required API key; used when `apiKey` is omitted. */
  readonly apiKey: "TYPESAFE_API_KEY";
  /** API root; defaults to `https://api.typesafe.ai`. */
  readonly baseURL: "TYPESAFE_BASE_URL";
  /** Default model name; defaults to `jev-latest`. */
  readonly defaultModel: "TYPESAFE_DEFAULT_MODEL";
  /** Log level; defaults to `warn`. */
  readonly logLevel: "TYPESAFE_LOG_LEVEL";
};
type EnvVar = (typeof ENV)[keyof typeof ENV];
//#endregion
//#region src/errors.d.ts
/** Base class for SDK errors. */
declare class TypeSafeError extends Error {
  constructor(message: string, options?: ErrorOptions);
}
/** An unsuccessful HTTP response from the API. */
declare class APIError extends TypeSafeError {
  /** HTTP response status code. */
  readonly status: number;
  /** HTTP response headers. */
  readonly headers: Headers;
  /** Parsed JSON, response text, or `undefined` for an empty body. */
  readonly body: unknown;
  /** Request ID from `x-typesafe-request-id`, or `undefined` when absent. */
  readonly requestId: string | undefined;
  constructor(status: number, body: unknown, headers: Headers, message?: string);
  private static describe;
  /** Create the error subclass for an HTTP status code. */
  static fromResponse(status: number, body: unknown, headers: Headers): APIError;
}
/** HTTP 400: the request is invalid. */
declare class BadRequestError extends APIError {}
/** HTTP 401: authentication failed. */
declare class AuthenticationError extends APIError {}
/** HTTP 403: access is denied. */
declare class PermissionDeniedError extends APIError {}
/** HTTP 404: the resource was not found. */
declare class NotFoundError extends APIError {}
/** HTTP 422: request validation failed. */
declare class UnprocessableEntityError extends APIError {}
/** HTTP 429: the rate limit was exceeded. */
declare class RateLimitError extends APIError {
  /** Server retry delay in milliseconds, or `undefined` when absent or invalid. */
  readonly retryAfterMs: number | undefined;
}
/** HTTP 5xx: the server failed to handle the request. */
declare class InternalServerError extends APIError {}
/** The request or response-body delivery failed (DNS, TLS, connection closed, etc.). */
declare class APIConnectionError extends TypeSafeError {
  constructor(message?: string, options?: ErrorOptions);
}
/** The full response did not arrive within the timeout. A kind of `APIConnectionError`. */
declare class APITimeoutError extends APIConnectionError {
  /** Configured timeout in milliseconds. */
  readonly timeoutMs: number;
  constructor(timeoutMs: number, options?: ErrorOptions);
}
/** The caller cancelled the request through an `AbortSignal`. */
declare class APIUserAbortError extends TypeSafeError {
  constructor(message?: string, options?: ErrorOptions);
}
//#endregion
//#region src/logging.d.ts
/** Supported log levels, from most to least verbose. */
declare const LOG_LEVELS: readonly LogLevel[];
//#endregion
//#region src/questions.d.ts
/**
 * Create a yes/no question with optional descriptions for either outcome.
 *
 * @param instructions - The question as text, a JSON object or array; defaults to `null`.
 * @param criteria - Optional descriptions of the yes and no outcomes.
 */
declare const noul: (instructions?: EntryType, criteria?: NoulQuestion["criteria"]) => NoulQuestion;
/**
 * Create a score question using an ordered rubric.
 *
 * @param instructions - The question as text, a JSON object or array, or `null`.
 * @param criteria - At least two descriptions indexed by score from zero; entries may be `null`.
 */
declare const score$1: <const T extends ScoreCriteria>(instructions: EntryType, criteria: T) => ScoreQuestion<T>;
/**
 * Create a question that selects between named alternatives.
 *
 * @param instructions - The question as text, a JSON object or array, or `null`.
 * @param criteria - Labels mapped to descriptions, or `null` for undescribed labels.
 */
declare const choice: <const T extends ChoiceCriteria>(instructions: EntryType, criteria: T) => ChoiceQuestion<T>;
//#endregion
//#region src/version.d.ts
declare const VERSION = "0.6.0";
//#endregion
export { APIConnectionError, APIError, APIPromise, APITimeoutError, APIUserAbortError, AuthenticationError, BadRequestError, type ChoiceCriteria, type ChoiceQuestion, type ChoiceResponse, type Description, ENV, type EntryType, type EnvVar, type Fetch, InternalServerError, type JsonValue, LOG_LEVELS, type LogLevel, type Logger, type ModelCard, type Models, NotFoundError, type NoulQuestion, type NoulResponse, PermissionDeniedError, type Question, type Questions, RateLimitError, type RequestOptions, type ResultFor, type RetryPolicy, type ScoreCriteria, type ScoreLegend, type ScoreOf, type ScoreQuestion, type ScoreResponse, type SystemOneRequest, type SystemOneRequestPayload, type SystemOneResult, TypeSafeClient, type TypeSafeClientConfig, TypeSafeError, UnprocessableEntityError, type Usage, VERSION, type WithResponse, choice, noul, score$1 as score };
//# sourceMappingURL=index.d.mts.map
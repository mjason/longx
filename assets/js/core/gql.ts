// The GraphQL transport: one endpoint (/gql), a plain POST of `{ query,
// variables }` with Phoenix's CSRF token (a native client puts its bearer
// token here), and `call`, which gives a generated operation the shape the
// hooks and the tests have always used — `listThreads({ input })` answering
// `{ success, data }` / `{ success: false, errors }` — so the API's move from
// the RPC to GraphQL is invisible above this file. The documents are strings
// (graphql-codegen's `documentMode: "string"`): no GraphQL runtime ships.
import type { TypedDocumentString } from "@/gql/graphql";

export type ApiError = { message: string; fields?: string[]; code?: string | null };
export type Result<T> = { success: true; data: T } | { success: false; errors: ApiError[] };

/**
 * A generated operation as a function: `input` (the arguments), `identity`
 * (a record's id); `D` is what the caller gets — the root field's value, or
 * the record under `result` of a create / update / destroy mutation.
 */
export type Call<Q extends object, V extends object, D> = ((args?: {
  input?: Record<string, unknown>;
  identity?: string;
}) => Promise<Result<D>>) & { readonly variables?: V };

export type Shape = {
  kind: "query" | "mutation";
  field: string;
  args: string[];
  wrapped: boolean;
  jsonArgs: string[];
  jsonInputs: string[];
};

export function csrfToken(doc: Document | undefined = globalThis.document): string | null {
  return doc?.querySelector('meta[name="csrf-token"]')?.getAttribute("content") ?? null;
}

const ENDPOINT = "/gql";

type GraphqlResponse<Q> = { data?: Q | null; errors?: { message: string; fields?: string[]; code?: string | null }[] };

/** The variables of an operation from the call's `{ input, identity }`. */
export function variablesFor(shape: Shape, args: { input?: Record<string, unknown>; identity?: string } = {}): Record<string, unknown> {
  const input = { ...(args.input ?? {}) };
  if (shape.kind === "query") return json(input, shape.jsonArgs);
  const vars: Record<string, unknown> = {};
  if (shape.args.includes("id")) {
    vars["id"] = args.identity ?? input["id"];
    delete input["id"];
  }
  for (const name of shape.args) {
    if (name === "id" || name === "input") continue;
    if (name in input) {
      vars[name] = input[name];
      delete input[name];
    }
  }
  if (shape.args.includes("input") && (Object.keys(input).length > 0 || !shape.args.includes("id"))) {
    vars["input"] = json(input, shape.jsonInputs);
  }
  return json(vars, shape.jsonArgs);
}

// a Json scalar reads a JSON string; its keys go out snake_case, as the
// server keeps them (the RPC formatted the keys of untyped maps both ways)
function json(map: Record<string, unknown>, fields: string[]): Record<string, unknown> {
  for (const f of fields) if (f in map && map[f] !== null && typeof map[f] !== "string") map[f] = JSON.stringify(deepKeys(map[f], snake));
  return map;
}

const camel = (s: string) => s.replace(/_([a-z0-9])/g, (_, c: string) => c.toUpperCase());
const snake = (s: string) => s.replace(/[A-Z]/g, (c) => "_" + c.toLowerCase());

/** every key of every plain object inside a value renamed (arrays walked) */
export function deepKeys(value: unknown, rename: (key: string) => string): unknown {
  if (Array.isArray(value)) return value.map((v) => deepKeys(v, rename));
  if (value && typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype) {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) out[rename(k)] = deepKeys(v, rename);
    return out;
  }
  return value;
}

/** GraphQL errors in the shape the UI reads: a message and the camelCased fields it concerns, deduplicated. */
export function errorsOf(errors: readonly { message: string; fields?: string[]; code?: string | null }[]): ApiError[] {
  const seen = new Set<string>();
  const out: ApiError[] = [];
  for (const e of errors) {
    const fields = (e.fields ?? []).map(camel);
    const key = `${e.message}|${fields.join(",")}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({ message: e.message, fields, code: e.code ?? null });
  }
  return out;
}

export function call<Q extends object, V extends object, D>(document: TypedDocumentString<Q, V>, shape: Shape): Call<Q, V, D> {
  return async (args = {}) => {
    const variables = variablesFor(shape, args);
    try {
      const response = await fetch(ENDPOINT, {
        method: "POST",
        credentials: "same-origin",
        headers: { "content-type": "application/json", accept: "application/json", ...headers() },
        body: JSON.stringify({ query: document.toString(), variables }),
      });
      const text = await response.text();
      let body: GraphqlResponse<Q>;
      try {
        body = JSON.parse(text) as GraphqlResponse<Q>;
      } catch {
        return { success: false, errors: [{ message: `HTTP ${response.status}: ${text.slice(0, 200)}`, fields: [] }] };
      }
      if (body.errors?.length) return { success: false, errors: errorsOf(body.errors) };
      const value = (body.data as Record<string, unknown> | null | undefined)?.[shape.field];
      const unwrapped = shape.wrapped && value && typeof value === "object" && "result" in (value as object) ? (value as { result: unknown }).result : value;
      // the keys inside a Json value come as the server keeps them (snake_case): camelCase, like every typed field
      return { success: true, data: deepKeys(unwrapped, camel) as D };
    } catch (e) {
      return { success: false, errors: [{ message: e instanceof Error ? e.message : String(e), fields: [] }] };
    }
  };
}

function headers(): Record<string, string> {
  const token = csrfToken();
  return token ? { "X-CSRF-Token": token } : {};
}

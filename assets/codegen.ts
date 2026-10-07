// graphql-codegen: the operations scripts/gql-client.mjs generates from the
// schema become typed documents in js/gql/ (the client preset). `npm run codegen`.
import type { CodegenConfig } from "@graphql-codegen/cli";
import { preset as clientPreset } from "@graphql-codegen/client-preset";

const config: CodegenConfig = {
  schema: "../priv/schema.graphql",
  // the operations live outside js/gql: the client preset leaves documents under its own output out
  documents: "js/core/operations.graphql",
  generates: {
    "js/gql/": {
      // The client preset's config whitelist does not forward pureMagicComment.
      preset: {
        ...clientPreset,
        async buildGeneratesSection(options) {
          const outputs = await clientPreset.buildGeneratesSection(options);
          return outputs.map((output) => ({
            ...output,
            config: { ...output.config, pureMagicComment: true },
          }));
        },
      },
      presetConfig: { fragmentMasking: false },
      config: {
        // documents as strings, not ASTs: nothing of the `graphql` package ships to the browser
        documentMode: "string",
        // an untyped map on the wire (config :ash_graphql, :json_type, :json) is any JSON value
        scalars: { Json: "unknown", DateTime: "string", Date: "string", Decimal: "string", NaiveDateTime: "string", Time: "string" },
        enumsAsTypes: true,
        skipTypename: true,
        useTypeImports: true,
        avoidOptionals: { field: true, inputValue: false, object: true },
      },
    },
  },
};

export default config;

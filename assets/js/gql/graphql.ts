/* eslint-disable */
/** Internal type. DO NOT USE DIRECTLY. */
type Exact<T extends { [key: string]: unknown }> = { [K in keyof T]: T[K] };
/** Internal type. DO NOT USE DIRECTLY. */
export type Incremental<T> = T | { [P in keyof T]?: P extends ' $fragmentName' | '__typename' ? T[P] : never };
import type { DocumentTypeDecoration } from '@graphql-typed-document-node/core';
export type AnswerRequestInput = {
  answers: unknown;
  requestId: string;
  threadId: string | number;
};

export type ApplyPresetInput = {
  apiKey?: string | null | undefined;
  makeDefault?: string | null | undefined;
  models?: Array<string> | null | undefined;
  slug: string;
};

export type ApproveChromeBrowserInput = {
  id: string;
};

export type CheckModelInput = {
  id: string | number;
};

export type ClearGoalInput = {
  threadId: string | number;
};

export type CompactThreadInput = {
  threadId: string | number;
};

export type CreateCredentialApiKeyInput = {
  allowedHosts?: Array<string> | null | undefined;
  header?: string | null | undefined;
  label?: string | null | undefined;
  name: string;
  scheme?: string | null | undefined;
  secret?: string | null | undefined;
};

export type CreateCredentialOauth2Input = {
  allowedHosts?: Array<string> | null | undefined;
  authorizeParams?: unknown;
  authorizeUrl?: string | null | undefined;
  clientId?: string | null | undefined;
  clientSecret?: string | null | undefined;
  deviceFlow?: string | null | undefined;
  extraParams?: unknown;
  fixedClient?: boolean | null | undefined;
  header?: string | null | undefined;
  label?: string | null | undefined;
  name: string;
  pkce?: boolean | null | undefined;
  redirectUri?: string | null | undefined;
  registrationUrl?: string | null | undefined;
  scheme?: string | null | undefined;
  scopes?: string | null | undefined;
  tokenUrl?: string | null | undefined;
};

export type CreateDirectoryInput = {
  name: string;
  parent: string;
};

export type CreateEntryInput = {
  kind: string;
  path: string;
  projectId: string | number;
};

export type CreateModelInput = {
  contextWindow?: number | null | undefined;
  hostedWebSearch?: boolean | null | undefined;
  imageGeneration?: boolean | null | undefined;
  maxOutputTokens?: number | null | undefined;
  name: string;
  providerId: string | number;
  reasoningEffort?: string | null | undefined;
  reasoningLevels?: Array<string> | null | undefined;
  reasoningSummary?: string | null | undefined;
  slug?: string | null | undefined;
  upstreamId: string;
  verbosity?: string | null | undefined;
};

export type CreateProjectInput = {
  agentSettings?: unknown;
  description?: string | null | undefined;
  initGit?: boolean | null | undefined;
  modelId?: string | number | null | undefined;
  name: string;
  rootPath: string;
  trustLocalAgent?: boolean | null | undefined;
  webSearch?: boolean | null | undefined;
};

export type CreateProviderInput = {
  apiKey?: string | null | undefined;
  baseUrl: string;
  credentialId?: string | number | null | undefined;
  kind?: string | null | undefined;
  maxConcurrentRequests?: number | null | undefined;
  name: string;
  promptCacheKey?: boolean | null | undefined;
  requestTimeoutMs?: number | null | undefined;
  slug: string;
  streamIdleTimeoutMs?: number | null | undefined;
  supportsHostedWebSearch?: boolean | null | undefined;
};

export type CredentialCompleteUrlInput = {
  url: string;
};

export type CredentialDeviceBeginInput = {
  id: string | number;
};

export type CredentialDevicePollInput = {
  state: string;
};

export type CredentialFilterAuthorizeParams = {
  eq?: unknown;
  greaterThan?: unknown;
  greaterThanOrEqual?: unknown;
  in?: Array<unknown> | null | undefined;
  isDistinctFrom?: unknown;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: unknown;
  lessThan?: unknown;
  lessThanOrEqual?: unknown;
  notEq?: unknown;
  rangeAdjacent?: unknown;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: unknown;
};

export type CredentialFilterAuthorizeUrl = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type CredentialFilterClientId = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type CredentialFilterDeviceFlow = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type CredentialFilterExpiresAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type CredentialFilterExtraParams = {
  eq?: unknown;
  greaterThan?: unknown;
  greaterThanOrEqual?: unknown;
  in?: Array<unknown> | null | undefined;
  isDistinctFrom?: unknown;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: unknown;
  lessThan?: unknown;
  lessThanOrEqual?: unknown;
  notEq?: unknown;
  rangeAdjacent?: unknown;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: unknown;
};

export type CredentialFilterFixedClient = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type CredentialFilterHasAccessToken = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type CredentialFilterHasClientSecret = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type CredentialFilterHasRefreshToken = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type CredentialFilterHasSecret = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type CredentialFilterHeader = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type CredentialFilterId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type CredentialFilterInput = {
  and?: Array<CredentialFilterInput> | null | undefined;
  authorizeParams?: CredentialFilterAuthorizeParams | null | undefined;
  authorizeUrl?: CredentialFilterAuthorizeUrl | null | undefined;
  clientId?: CredentialFilterClientId | null | undefined;
  deviceFlow?: CredentialFilterDeviceFlow | null | undefined;
  expiresAt?: CredentialFilterExpiresAt | null | undefined;
  extraParams?: CredentialFilterExtraParams | null | undefined;
  fixedClient?: CredentialFilterFixedClient | null | undefined;
  hasAccessToken?: CredentialFilterHasAccessToken | null | undefined;
  hasClientSecret?: CredentialFilterHasClientSecret | null | undefined;
  hasRefreshToken?: CredentialFilterHasRefreshToken | null | undefined;
  hasSecret?: CredentialFilterHasSecret | null | undefined;
  header?: CredentialFilterHeader | null | undefined;
  id?: CredentialFilterId | null | undefined;
  insertedAt?: CredentialFilterInsertedAt | null | undefined;
  kind?: CredentialFilterKind | null | undefined;
  label?: CredentialFilterLabel | null | undefined;
  lastError?: CredentialFilterLastError | null | undefined;
  lastErrorAt?: CredentialFilterLastErrorAt | null | undefined;
  name?: CredentialFilterName | null | undefined;
  not?: Array<CredentialFilterInput> | null | undefined;
  or?: Array<CredentialFilterInput> | null | undefined;
  pkce?: CredentialFilterPkce | null | undefined;
  redirectUri?: CredentialFilterRedirectUri | null | undefined;
  refreshedAt?: CredentialFilterRefreshedAt | null | undefined;
  registrationUrl?: CredentialFilterRegistrationUrl | null | undefined;
  scheme?: CredentialFilterScheme | null | undefined;
  scopes?: CredentialFilterScopes | null | undefined;
  tokenUrl?: CredentialFilterTokenUrl | null | undefined;
  updatedAt?: CredentialFilterUpdatedAt | null | undefined;
};

export type CredentialFilterInsertedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type CredentialFilterKind = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type CredentialFilterLabel = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type CredentialFilterLastError = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type CredentialFilterLastErrorAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type CredentialFilterName = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type CredentialFilterPkce = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type CredentialFilterRedirectUri = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type CredentialFilterRefreshedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type CredentialFilterRegistrationUrl = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type CredentialFilterScheme = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type CredentialFilterScopes = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type CredentialFilterTokenUrl = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type CredentialFilterUpdatedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type CredentialLoginUrlInput = {
  id: string | number;
  origin?: string | null | undefined;
};

export type CredentialSortField =
  | 'AUTHORIZE_PARAMS'
  | 'AUTHORIZE_URL'
  | 'CLIENT_ID'
  | 'DEVICE_FLOW'
  | 'EXPIRES_AT'
  | 'EXTRA_PARAMS'
  | 'FIXED_CLIENT'
  | 'HAS_ACCESS_TOKEN'
  | 'HAS_CLIENT_SECRET'
  | 'HAS_REFRESH_TOKEN'
  | 'HAS_SECRET'
  | 'HEADER'
  | 'ID'
  | 'INSERTED_AT'
  | 'KIND'
  | 'LABEL'
  | 'LAST_ERROR'
  | 'LAST_ERROR_AT'
  | 'NAME'
  | 'PKCE'
  | 'REDIRECT_URI'
  | 'REFRESHED_AT'
  | 'REGISTRATION_URL'
  | 'SCHEME'
  | 'SCOPES'
  | 'TOKEN_URL'
  | 'UPDATED_AT';

export type CredentialSortInput = {
  field: CredentialSortField;
  order?: SortOrder | null | undefined;
};

export type DeleteChromeAliasInput = {
  name: string;
};

export type DeleteEntryInput = {
  path: string;
  projectId: string | number;
};

export type DeleteModelAliasInput = {
  name: string;
};

export type DeleteProjectInput = {
  confirm?: boolean | null | undefined;
};

export type DeleteThreadInput = {
  threadId: string | number;
};

export type DeleteWatchInput = {
  id: string | number;
};

export type DiscoverModelsInput = {
  id: string | number;
};

export type DryRunWatchInput = {
  id: string | number;
};

export type GitAbortMergeInput = {
  projectId: string | number;
};

export type GitCommitInput = {
  message: string;
  paths: Array<string>;
  projectId: string | number;
};

export type GitCreateBranchInput = {
  name: string;
  projectId: string | number;
};

export type GitDeleteBranchInput = {
  force?: boolean | null | undefined;
  name: string;
  projectId: string | number;
};

export type GitDiscardInput = {
  paths: Array<string>;
  projectId: string | number;
};

export type GitFetchInput = {
  projectId: string | number;
};

export type GitPullInput = {
  projectId: string | number;
};

export type GitPushInput = {
  projectId: string | number;
};

export type GitSetRemoteInput = {
  name: string;
  projectId: string | number;
  url: string;
};

export type GitStashPopInput = {
  projectId: string | number;
};

export type GitSwitchInput = {
  name: string;
  projectId: string | number;
  stash?: boolean | null | undefined;
};

export type GitUndoCommitInput = {
  projectId: string | number;
};

export type InitGitInput = {
  id: string | number;
};

export type InterruptTurnInput = {
  kernelTurnId: string;
  threadId: string | number;
};

export type KillCommandInput = {
  id: string;
};

export type KnowledgeDeleteInput = {
  path: string;
};

export type KnowledgeWriteInput = {
  content: string;
  path: string;
};

export type ModelFilterContextWindow = {
  eq?: number | null | undefined;
  greaterThan?: number | null | undefined;
  greaterThanOrEqual?: number | null | undefined;
  in?: Array<number> | null | undefined;
  isDistinctFrom?: number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: number | null | undefined;
  lessThan?: number | null | undefined;
  lessThanOrEqual?: number | null | undefined;
  notEq?: number | null | undefined;
  rangeAdjacent?: number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: number | null | undefined;
};

export type ModelFilterDefault = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type ModelFilterHostedWebSearch = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean | null | undefined> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type ModelFilterId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type ModelFilterImageGeneration = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type ModelFilterInput = {
  and?: Array<ModelFilterInput> | null | undefined;
  contextWindow?: ModelFilterContextWindow | null | undefined;
  default?: ModelFilterDefault | null | undefined;
  hostedWebSearch?: ModelFilterHostedWebSearch | null | undefined;
  id?: ModelFilterId | null | undefined;
  imageGeneration?: ModelFilterImageGeneration | null | undefined;
  insertedAt?: ModelFilterInsertedAt | null | undefined;
  maxOutputTokens?: ModelFilterMaxOutputTokens | null | undefined;
  name?: ModelFilterName | null | undefined;
  not?: Array<ModelFilterInput> | null | undefined;
  or?: Array<ModelFilterInput> | null | undefined;
  provider?: ProviderFilterInput | null | undefined;
  providerId?: ModelFilterProviderId | null | undefined;
  reasoningEffort?: ModelFilterReasoningEffort | null | undefined;
  reasoningSummary?: ModelFilterReasoningSummary | null | undefined;
  slug?: ModelFilterSlug | null | undefined;
  updatedAt?: ModelFilterUpdatedAt | null | undefined;
  upstreamId?: ModelFilterUpstreamId | null | undefined;
  verbosity?: ModelFilterVerbosity | null | undefined;
};

export type ModelFilterInsertedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type ModelFilterMaxOutputTokens = {
  eq?: number | null | undefined;
  greaterThan?: number | null | undefined;
  greaterThanOrEqual?: number | null | undefined;
  in?: Array<number | null | undefined> | null | undefined;
  isDistinctFrom?: number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: number | null | undefined;
  lessThan?: number | null | undefined;
  lessThanOrEqual?: number | null | undefined;
  notEq?: number | null | undefined;
  rangeAdjacent?: number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: number | null | undefined;
};

export type ModelFilterName = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ModelFilterProviderId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type ModelFilterReasoningEffort = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ModelFilterReasoningSummary = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type ModelFilterSlug = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ModelFilterUpdatedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type ModelFilterUpstreamId = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ModelFilterVerbosity = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ModelSortField =
  | 'CONTEXT_WINDOW'
  | 'DEFAULT'
  | 'HOSTED_WEB_SEARCH'
  | 'ID'
  | 'IMAGE_GENERATION'
  | 'INSERTED_AT'
  | 'MAX_OUTPUT_TOKENS'
  | 'NAME'
  | 'PROVIDER_ID'
  | 'REASONING_EFFORT'
  | 'REASONING_SUMMARY'
  | 'SLUG'
  | 'UPDATED_AT'
  | 'UPSTREAM_ID'
  | 'VERBOSITY';

export type ModelSortInput = {
  field: ModelSortField;
  order?: SortOrder | null | undefined;
};

export type ProjectFilterAgentSettings = {
  eq?: unknown;
  greaterThan?: unknown;
  greaterThanOrEqual?: unknown;
  in?: Array<unknown> | null | undefined;
  isDistinctFrom?: unknown;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: unknown;
  lessThan?: unknown;
  lessThanOrEqual?: unknown;
  notEq?: unknown;
  rangeAdjacent?: unknown;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: unknown;
};

export type ProjectFilterArchivedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type ProjectFilterDescription = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ProjectFilterFileRules = {
  eq?: unknown;
  greaterThan?: unknown;
  greaterThanOrEqual?: unknown;
  in?: Array<unknown> | null | undefined;
  isDistinctFrom?: unknown;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: unknown;
  lessThan?: unknown;
  lessThanOrEqual?: unknown;
  notEq?: unknown;
  rangeAdjacent?: unknown;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: unknown;
};

export type ProjectFilterId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type ProjectFilterInput = {
  agentSettings?: ProjectFilterAgentSettings | null | undefined;
  and?: Array<ProjectFilterInput> | null | undefined;
  archivedAt?: ProjectFilterArchivedAt | null | undefined;
  description?: ProjectFilterDescription | null | undefined;
  fileRules?: ProjectFilterFileRules | null | undefined;
  id?: ProjectFilterId | null | undefined;
  insertedAt?: ProjectFilterInsertedAt | null | undefined;
  model?: ModelFilterInput | null | undefined;
  modelId?: ProjectFilterModelId | null | undefined;
  name?: ProjectFilterName | null | undefined;
  not?: Array<ProjectFilterInput> | null | undefined;
  or?: Array<ProjectFilterInput> | null | undefined;
  rootPath?: ProjectFilterRootPath | null | undefined;
  slug?: ProjectFilterSlug | null | undefined;
  trustLocalAgent?: ProjectFilterTrustLocalAgent | null | undefined;
  updatedAt?: ProjectFilterUpdatedAt | null | undefined;
  webSearch?: ProjectFilterWebSearch | null | undefined;
};

export type ProjectFilterInsertedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type ProjectFilterModelId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number | null | undefined> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type ProjectFilterName = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ProjectFilterRootPath = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ProjectFilterSlug = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ProjectFilterTrustLocalAgent = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type ProjectFilterUpdatedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type ProjectFilterWebSearch = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type ProjectSortField =
  | 'AGENT_SETTINGS'
  | 'ARCHIVED_AT'
  | 'DESCRIPTION'
  | 'FILE_RULES'
  | 'ID'
  | 'INSERTED_AT'
  | 'MODEL_ID'
  | 'NAME'
  | 'ROOT_PATH'
  | 'SLUG'
  | 'TRUST_LOCAL_AGENT'
  | 'UPDATED_AT'
  | 'WEB_SEARCH';

export type ProjectSortInput = {
  field: ProjectSortField;
  order?: SortOrder | null | undefined;
};

export type PromoteLocalInput = {
  id: string | number;
  path: string;
};

export type ProviderFilterBaseUrl = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ProviderFilterCredentialId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number | null | undefined> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type ProviderFilterHasApiKey = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type ProviderFilterId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type ProviderFilterInput = {
  and?: Array<ProviderFilterInput> | null | undefined;
  baseUrl?: ProviderFilterBaseUrl | null | undefined;
  credentialId?: ProviderFilterCredentialId | null | undefined;
  hasApiKey?: ProviderFilterHasApiKey | null | undefined;
  id?: ProviderFilterId | null | undefined;
  insertedAt?: ProviderFilterInsertedAt | null | undefined;
  kind?: ProviderFilterKind | null | undefined;
  lastCheckedAt?: ProviderFilterLastCheckedAt | null | undefined;
  lastError?: ProviderFilterLastError | null | undefined;
  lastErrorAt?: ProviderFilterLastErrorAt | null | undefined;
  maxConcurrentRequests?: ProviderFilterMaxConcurrentRequests | null | undefined;
  name?: ProviderFilterName | null | undefined;
  not?: Array<ProviderFilterInput> | null | undefined;
  or?: Array<ProviderFilterInput> | null | undefined;
  promptCacheKey?: ProviderFilterPromptCacheKey | null | undefined;
  requestTimeoutMs?: ProviderFilterRequestTimeoutMs | null | undefined;
  slug?: ProviderFilterSlug | null | undefined;
  streamIdleTimeoutMs?: ProviderFilterStreamIdleTimeoutMs | null | undefined;
  supportsHostedWebSearch?: ProviderFilterSupportsHostedWebSearch | null | undefined;
  updatedAt?: ProviderFilterUpdatedAt | null | undefined;
};

export type ProviderFilterInsertedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type ProviderFilterKind = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type ProviderFilterLastCheckedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type ProviderFilterLastError = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ProviderFilterLastErrorAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type ProviderFilterMaxConcurrentRequests = {
  eq?: number | null | undefined;
  greaterThan?: number | null | undefined;
  greaterThanOrEqual?: number | null | undefined;
  in?: Array<number | null | undefined> | null | undefined;
  isDistinctFrom?: number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: number | null | undefined;
  lessThan?: number | null | undefined;
  lessThanOrEqual?: number | null | undefined;
  notEq?: number | null | undefined;
  rangeAdjacent?: number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: number | null | undefined;
};

export type ProviderFilterName = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ProviderFilterPromptCacheKey = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean | null | undefined> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type ProviderFilterRequestTimeoutMs = {
  eq?: number | null | undefined;
  greaterThan?: number | null | undefined;
  greaterThanOrEqual?: number | null | undefined;
  in?: Array<number> | null | undefined;
  isDistinctFrom?: number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: number | null | undefined;
  lessThan?: number | null | undefined;
  lessThanOrEqual?: number | null | undefined;
  notEq?: number | null | undefined;
  rangeAdjacent?: number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: number | null | undefined;
};

export type ProviderFilterSlug = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ProviderFilterStreamIdleTimeoutMs = {
  eq?: number | null | undefined;
  greaterThan?: number | null | undefined;
  greaterThanOrEqual?: number | null | undefined;
  in?: Array<number> | null | undefined;
  isDistinctFrom?: number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: number | null | undefined;
  lessThan?: number | null | undefined;
  lessThanOrEqual?: number | null | undefined;
  notEq?: number | null | undefined;
  rangeAdjacent?: number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: number | null | undefined;
};

export type ProviderFilterSupportsHostedWebSearch = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type ProviderFilterUpdatedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type ProviderSortField =
  | 'BASE_URL'
  | 'CREDENTIAL_ID'
  | 'HAS_API_KEY'
  | 'ID'
  | 'INSERTED_AT'
  | 'KIND'
  | 'LAST_CHECKED_AT'
  | 'LAST_ERROR'
  | 'LAST_ERROR_AT'
  | 'MAX_CONCURRENT_REQUESTS'
  | 'NAME'
  | 'PROMPT_CACHE_KEY'
  | 'REQUEST_TIMEOUT_MS'
  | 'SLUG'
  | 'STREAM_IDLE_TIMEOUT_MS'
  | 'SUPPORTS_HOSTED_WEB_SEARCH'
  | 'UPDATED_AT';

export type ProviderSortInput = {
  field: ProviderSortField;
  order?: SortOrder | null | undefined;
};

export type RefreshCredentialInput = {
  id: string | number;
};

export type RejectChromeBrowserInput = {
  id: string;
};

export type ReleaseWaitingInput = {
  threadId: string | number;
  waitingId: string;
};

export type RenameChromeBrowserInput = {
  id: string;
  name: string;
};

export type RenameEntryInput = {
  from: string;
  projectId: string | number;
  to: string;
};

export type RenameThreadInput = {
  title?: string | null | undefined;
};

export type RetractTurnInput = {
  kernelTurnId: string;
  threadId: string | number;
};

export type RevokeChromeBrowserInput = {
  id: string;
};

export type SearchProviderFilterBaseUrl = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type SearchProviderFilterDefault = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type SearchProviderFilterHasApiKey = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type SearchProviderFilterId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type SearchProviderFilterInput = {
  and?: Array<SearchProviderFilterInput> | null | undefined;
  baseUrl?: SearchProviderFilterBaseUrl | null | undefined;
  default?: SearchProviderFilterDefault | null | undefined;
  hasApiKey?: SearchProviderFilterHasApiKey | null | undefined;
  id?: SearchProviderFilterId | null | undefined;
  kind?: SearchProviderFilterKind | null | undefined;
  name?: SearchProviderFilterName | null | undefined;
  not?: Array<SearchProviderFilterInput> | null | undefined;
  or?: Array<SearchProviderFilterInput> | null | undefined;
  slug?: SearchProviderFilterSlug | null | undefined;
};

export type SearchProviderFilterKind = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type SearchProviderFilterName = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type SearchProviderFilterSlug = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type SearchProviderSortField =
  | 'BASE_URL'
  | 'DEFAULT'
  | 'HAS_API_KEY'
  | 'ID'
  | 'KIND'
  | 'NAME'
  | 'SLUG';

export type SearchProviderSortInput = {
  field: SearchProviderSortField;
  order?: SortOrder | null | undefined;
};

export type SendMessageInput = {
  effort?: string | null | undefined;
  images?: Array<string> | null | undefined;
  model?: string | null | undefined;
  text: string;
  threadId: string | number;
};

export type SetAgentSettingsInput = {
  childEffort?: string | null | undefined;
  childModel?: string | null | undefined;
  commandOomPriority?: number | null | undefined;
  commandShell?: string | null | undefined;
  idleMinutes?: number | null | undefined;
  maxChildren?: number | null | undefined;
  maxDepth?: number | null | undefined;
  memoryFloorPercent?: number | null | undefined;
  modelRetries?: number | null | undefined;
};

export type SetBrowserPrivateNetworkInput = {
  enabled: boolean;
};

export type SetChromeAliasInput = {
  browsers: Array<string>;
  name: string;
};

export type SetChromeBrowserMaxTabsInput = {
  id: string;
  maxTabs: number;
};

export type SetChromeDefaultAliasInput = {
  name?: string | null | undefined;
};

export type SetDefaultModelInput = {
  name: string;
};

export type SetFileRulesInput = {
  ignore?: string | null | undefined;
  watch?: string | null | undefined;
};

export type SetGithubTokenInput = {
  token?: string | null | undefined;
};

export type SetGoalInput = {
  objective?: string | null | undefined;
  status?: string | null | undefined;
  threadId: string | number;
  tokenBudget?: number | null | undefined;
};

export type SetModelAliasInput = {
  efforts?: Array<string | null | undefined> | null | undefined;
  models: Array<string>;
  name: string;
};

export type SetPublicUrlInput = {
  url: string;
};

export type SetSentryDsnInput = {
  dsn: string;
};

export type SetThreadHandleInput = {
  handle?: string | null | undefined;
  threadId: string | number;
};

export type SetThreadOnDutyInput = {
  onDuty: boolean;
  threadId: string | number;
};

export type SetTlsInput = {
  directory?: string | null | undefined;
  domains?: Array<string> | null | undefined;
  email?: string | null | undefined;
  enabled?: boolean | null | undefined;
  env?: Array<TlsVariableInput> | null | undefined;
  port?: number | null | undefined;
  propagationCheck?: boolean | null | undefined;
  propagationWait?: number | null | undefined;
  provider?: string | null | undefined;
  redirect?: boolean | null | undefined;
  resolvers?: Array<string> | null | undefined;
};

export type SortOrder =
  | 'ASC'
  | 'ASC_NULLS_FIRST'
  | 'ASC_NULLS_LAST'
  | 'DESC'
  | 'DESC_NULLS_FIRST'
  | 'DESC_NULLS_LAST';

export type StartThreadInput = {
  effort?: string | null | undefined;
  model?: string | null | undefined;
  projectId: string | number;
  webSearch?: boolean | null | undefined;
};

export type SteerTurnInput = {
  images?: Array<string> | null | undefined;
  text: string;
  threadId: string | number;
};

export type SwitchWatchInput = {
  enabled: boolean;
  id: string | number;
};

export type ThreadFilterAgentPath = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ThreadFilterCwd = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ThreadFilterHandle = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ThreadFilterId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type ThreadFilterInput = {
  agentPath?: ThreadFilterAgentPath | null | undefined;
  and?: Array<ThreadFilterInput> | null | undefined;
  cwd?: ThreadFilterCwd | null | undefined;
  handle?: ThreadFilterHandle | null | undefined;
  id?: ThreadFilterId | null | undefined;
  insertedAt?: ThreadFilterInsertedAt | null | undefined;
  kernelThreadId?: ThreadFilterKernelThreadId | null | undefined;
  lastActivityAt?: ThreadFilterLastActivityAt | null | undefined;
  modelSlug?: ThreadFilterModelSlug | null | undefined;
  not?: Array<ThreadFilterInput> | null | undefined;
  onDuty?: ThreadFilterOnDuty | null | undefined;
  or?: Array<ThreadFilterInput> | null | undefined;
  parentThread?: ThreadFilterInput | null | undefined;
  parentThreadId?: ThreadFilterParentThreadId | null | undefined;
  preview?: ThreadFilterPreview | null | undefined;
  project?: ProjectFilterInput | null | undefined;
  projectId?: ThreadFilterProjectId | null | undefined;
  reasoningEffort?: ThreadFilterReasoningEffort | null | undefined;
  status?: ThreadFilterStatus | null | undefined;
  title?: ThreadFilterTitle | null | undefined;
  updatedAt?: ThreadFilterUpdatedAt | null | undefined;
  webSearch?: ThreadFilterWebSearch | null | undefined;
};

export type ThreadFilterInsertedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type ThreadFilterKernelThreadId = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ThreadFilterLastActivityAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type ThreadFilterModelSlug = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ThreadFilterOnDuty = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type ThreadFilterParentThreadId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number | null | undefined> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type ThreadFilterPreview = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ThreadFilterProjectId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type ThreadFilterReasoningEffort = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ThreadFilterStatus = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type ThreadFilterTitle = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type ThreadFilterUpdatedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type ThreadFilterWebSearch = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type ThreadSortField =
  | 'AGENT_PATH'
  | 'CWD'
  | 'HANDLE'
  | 'ID'
  | 'INSERTED_AT'
  | 'KERNEL_THREAD_ID'
  | 'LAST_ACTIVITY_AT'
  | 'MODEL_SLUG'
  | 'ON_DUTY'
  | 'PARENT_THREAD_ID'
  | 'PREVIEW'
  | 'PROJECT_ID'
  | 'REASONING_EFFORT'
  | 'STATUS'
  | 'TITLE'
  | 'UPDATED_AT'
  | 'WEB_SEARCH';

export type ThreadSortInput = {
  field: ThreadSortField;
  order?: SortOrder | null | undefined;
};

export type TlsVariableInput = {
  name: string;
  value?: string | null | undefined;
};

export type TurnFilterCompletedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type TurnFilterError = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type TurnFilterId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type TurnFilterInput = {
  and?: Array<TurnFilterInput> | null | undefined;
  completedAt?: TurnFilterCompletedAt | null | undefined;
  error?: TurnFilterError | null | undefined;
  id?: TurnFilterId | null | undefined;
  insertedAt?: TurnFilterInsertedAt | null | undefined;
  kernelTurnId?: TurnFilterKernelTurnId | null | undefined;
  modelSlug?: TurnFilterModelSlug | null | undefined;
  not?: Array<TurnFilterInput> | null | undefined;
  or?: Array<TurnFilterInput> | null | undefined;
  reasoningEffort?: TurnFilterReasoningEffort | null | undefined;
  startedAt?: TurnFilterStartedAt | null | undefined;
  status?: TurnFilterStatus | null | undefined;
  thread?: ThreadFilterInput | null | undefined;
  threadId?: TurnFilterThreadId | null | undefined;
  updatedAt?: TurnFilterUpdatedAt | null | undefined;
  usage?: TurnFilterUsage | null | undefined;
  userText?: TurnFilterUserText | null | undefined;
};

export type TurnFilterInsertedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type TurnFilterKernelTurnId = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type TurnFilterModelSlug = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type TurnFilterReasoningEffort = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type TurnFilterStartedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type TurnFilterStatus = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type TurnFilterThreadId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type TurnFilterUpdatedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type TurnFilterUsage = {
  eq?: unknown;
  greaterThan?: unknown;
  greaterThanOrEqual?: unknown;
  in?: Array<unknown> | null | undefined;
  isDistinctFrom?: unknown;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: unknown;
  lessThan?: unknown;
  lessThanOrEqual?: unknown;
  notEq?: unknown;
  rangeAdjacent?: unknown;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: unknown;
};

export type TurnFilterUserText = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type TurnSortField =
  | 'COMPLETED_AT'
  | 'ERROR'
  | 'ID'
  | 'INSERTED_AT'
  | 'KERNEL_TURN_ID'
  | 'MODEL_SLUG'
  | 'REASONING_EFFORT'
  | 'STARTED_AT'
  | 'STATUS'
  | 'THREAD_ID'
  | 'UPDATED_AT'
  | 'USAGE'
  | 'USER_TEXT';

export type TurnSortInput = {
  field: TurnSortField;
  order?: SortOrder | null | undefined;
};

export type UpdateCredentialInput = {
  allowedHosts?: Array<string> | null | undefined;
  authorizeParams?: unknown;
  authorizeUrl?: string | null | undefined;
  clientId?: string | null | undefined;
  clientSecret?: string | null | undefined;
  deviceFlow?: string | null | undefined;
  extraParams?: unknown;
  fixedClient?: boolean | null | undefined;
  header?: string | null | undefined;
  label?: string | null | undefined;
  pkce?: boolean | null | undefined;
  redirectUri?: string | null | undefined;
  registrationUrl?: string | null | undefined;
  scheme?: string | null | undefined;
  scopes?: string | null | undefined;
  secret?: string | null | undefined;
  tokenUrl?: string | null | undefined;
};

export type UpdateModelInput = {
  contextWindow?: number | null | undefined;
  hostedWebSearch?: boolean | null | undefined;
  imageGeneration?: boolean | null | undefined;
  maxOutputTokens?: number | null | undefined;
  name?: string | null | undefined;
  reasoningEffort?: string | null | undefined;
  reasoningLevels?: Array<string> | null | undefined;
  reasoningSummary?: string | null | undefined;
  slug?: string | null | undefined;
  upstreamId?: string | null | undefined;
  verbosity?: string | null | undefined;
};

export type UpdateProjectInput = {
  agentSettings?: unknown;
  description?: string | null | undefined;
  fileRules?: unknown;
  modelId?: string | number | null | undefined;
  name?: string | null | undefined;
  slug?: string | null | undefined;
  trustLocalAgent?: boolean | null | undefined;
  webSearch?: boolean | null | undefined;
};

export type UpdateProviderInput = {
  apiKey?: string | null | undefined;
  baseUrl?: string | null | undefined;
  credentialId?: string | number | null | undefined;
  kind?: string | null | undefined;
  maxConcurrentRequests?: number | null | undefined;
  name?: string | null | undefined;
  promptCacheKey?: boolean | null | undefined;
  requestTimeoutMs?: number | null | undefined;
  streamIdleTimeoutMs?: number | null | undefined;
  supportsHostedWebSearch?: boolean | null | undefined;
};

export type UpdateSearchProviderInput = {
  apiKey?: string | null | undefined;
  baseUrl?: string | null | undefined;
  name?: string | null | undefined;
};

export type WatchFilterAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type WatchFilterBudgetPerHour = {
  eq?: number | null | undefined;
  greaterThan?: number | null | undefined;
  greaterThanOrEqual?: number | null | undefined;
  in?: Array<number> | null | undefined;
  isDistinctFrom?: number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: number | null | undefined;
  lessThan?: number | null | undefined;
  lessThanOrEqual?: number | null | undefined;
  notEq?: number | null | undefined;
  rangeAdjacent?: number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: number | null | undefined;
};

export type WatchFilterCron = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type WatchFilterDisabledReason = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type WatchFilterEnabled = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type WatchFilterExpiresAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type WatchFilterHourStartedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type WatchFilterId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type WatchFilterInput = {
  and?: Array<WatchFilterInput> | null | undefined;
  at?: WatchFilterAt | null | undefined;
  budgetPerHour?: WatchFilterBudgetPerHour | null | undefined;
  cron?: WatchFilterCron | null | undefined;
  disabledReason?: WatchFilterDisabledReason | null | undefined;
  enabled?: WatchFilterEnabled | null | undefined;
  expiresAt?: WatchFilterExpiresAt | null | undefined;
  hourStartedAt?: WatchFilterHourStartedAt | null | undefined;
  id?: WatchFilterId | null | undefined;
  insertedAt?: WatchFilterInsertedAt | null | undefined;
  kind?: WatchFilterKind | null | undefined;
  lastDurationMs?: WatchFilterLastDurationMs | null | undefined;
  lastError?: WatchFilterLastError | null | undefined;
  lastOutput?: WatchFilterLastOutput | null | undefined;
  lastRunAt?: WatchFilterLastRunAt | null | undefined;
  lastSentTo?: WatchFilterLastSentTo | null | undefined;
  layer?: WatchFilterLayer | null | undefined;
  loadError?: WatchFilterLoadError | null | undefined;
  maxRuns?: WatchFilterMaxRuns | null | undefined;
  name?: WatchFilterName | null | undefined;
  nextDueAt?: WatchFilterNextDueAt | null | undefined;
  not?: Array<WatchFilterInput> | null | undefined;
  or?: Array<WatchFilterInput> | null | undefined;
  path?: WatchFilterPath | null | undefined;
  project?: ProjectFilterInput | null | undefined;
  projectId?: WatchFilterProjectId | null | undefined;
  runningSince?: WatchFilterRunningSince | null | undefined;
  runs?: WatchFilterRuns | null | undefined;
  sends?: WatchFilterSends | null | undefined;
  sendsThisHour?: WatchFilterSendsThisHour | null | undefined;
  state?: WatchFilterState | null | undefined;
  timeoutMs?: WatchFilterTimeoutMs | null | undefined;
  updatedAt?: WatchFilterUpdatedAt | null | undefined;
  webhookToken?: WatchFilterWebhookToken | null | undefined;
};

export type WatchFilterInsertedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type WatchFilterKind = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type WatchFilterLastDurationMs = {
  eq?: number | null | undefined;
  greaterThan?: number | null | undefined;
  greaterThanOrEqual?: number | null | undefined;
  in?: Array<number | null | undefined> | null | undefined;
  isDistinctFrom?: number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: number | null | undefined;
  lessThan?: number | null | undefined;
  lessThanOrEqual?: number | null | undefined;
  notEq?: number | null | undefined;
  rangeAdjacent?: number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: number | null | undefined;
};

export type WatchFilterLastError = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type WatchFilterLastOutput = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type WatchFilterLastRunAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type WatchFilterLastSentTo = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type WatchFilterLayer = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type WatchFilterLoadError = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type WatchFilterMaxRuns = {
  eq?: number | null | undefined;
  greaterThan?: number | null | undefined;
  greaterThanOrEqual?: number | null | undefined;
  in?: Array<number | null | undefined> | null | undefined;
  isDistinctFrom?: number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: number | null | undefined;
  lessThan?: number | null | undefined;
  lessThanOrEqual?: number | null | undefined;
  notEq?: number | null | undefined;
  rangeAdjacent?: number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: number | null | undefined;
};

export type WatchFilterName = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type WatchFilterNextDueAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type WatchFilterPath = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type WatchFilterProjectId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type WatchFilterRunningSince = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type WatchFilterRuns = {
  eq?: number | null | undefined;
  greaterThan?: number | null | undefined;
  greaterThanOrEqual?: number | null | undefined;
  in?: Array<number> | null | undefined;
  isDistinctFrom?: number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: number | null | undefined;
  lessThan?: number | null | undefined;
  lessThanOrEqual?: number | null | undefined;
  notEq?: number | null | undefined;
  rangeAdjacent?: number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: number | null | undefined;
};

export type WatchFilterSends = {
  eq?: number | null | undefined;
  greaterThan?: number | null | undefined;
  greaterThanOrEqual?: number | null | undefined;
  in?: Array<number> | null | undefined;
  isDistinctFrom?: number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: number | null | undefined;
  lessThan?: number | null | undefined;
  lessThanOrEqual?: number | null | undefined;
  notEq?: number | null | undefined;
  rangeAdjacent?: number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: number | null | undefined;
};

export type WatchFilterSendsThisHour = {
  eq?: number | null | undefined;
  greaterThan?: number | null | undefined;
  greaterThanOrEqual?: number | null | undefined;
  in?: Array<number> | null | undefined;
  isDistinctFrom?: number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: number | null | undefined;
  lessThan?: number | null | undefined;
  lessThanOrEqual?: number | null | undefined;
  notEq?: number | null | undefined;
  rangeAdjacent?: number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: number | null | undefined;
};

export type WatchFilterState = {
  eq?: unknown;
  greaterThan?: unknown;
  greaterThanOrEqual?: unknown;
  in?: Array<unknown> | null | undefined;
  isDistinctFrom?: unknown;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: unknown;
  lessThan?: unknown;
  lessThanOrEqual?: unknown;
  notEq?: unknown;
  rangeAdjacent?: unknown;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: unknown;
};

export type WatchFilterTimeoutMs = {
  eq?: number | null | undefined;
  greaterThan?: number | null | undefined;
  greaterThanOrEqual?: number | null | undefined;
  in?: Array<number> | null | undefined;
  isDistinctFrom?: number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: number | null | undefined;
  lessThan?: number | null | undefined;
  lessThanOrEqual?: number | null | undefined;
  notEq?: number | null | undefined;
  rangeAdjacent?: number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: number | null | undefined;
};

export type WatchFilterUpdatedAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type WatchFilterWebhookToken = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type WatchSortField =
  | 'AT'
  | 'BUDGET_PER_HOUR'
  | 'CRON'
  | 'DISABLED_REASON'
  | 'ENABLED'
  | 'EXPIRES_AT'
  | 'HOUR_STARTED_AT'
  | 'ID'
  | 'INSERTED_AT'
  | 'KIND'
  | 'LAST_DURATION_MS'
  | 'LAST_ERROR'
  | 'LAST_OUTPUT'
  | 'LAST_RUN_AT'
  | 'LAST_SENT_TO'
  | 'LAYER'
  | 'LOAD_ERROR'
  | 'MAX_RUNS'
  | 'NAME'
  | 'NEXT_DUE_AT'
  | 'PATH'
  | 'PROJECT_ID'
  | 'RUNNING_SINCE'
  | 'RUNS'
  | 'SENDS'
  | 'SENDS_THIS_HOUR'
  | 'STATE'
  | 'TIMEOUT_MS'
  | 'UPDATED_AT'
  | 'WEBHOOK_TOKEN';

export type WatchSortInput = {
  field: WatchSortField;
  order?: SortOrder | null | undefined;
};

export type WriteFileInput = {
  content: string;
  path: string;
  projectId: string | number;
};

export type ListWatchesQueryVariables = Exact<{
  sort?: Array<WatchSortInput | null | undefined> | WatchSortInput | null | undefined;
  filter?: WatchFilterInput | null | undefined;
  projectId: string | number;
}>;


export type ListWatchesQuery = { listWatches: Array<{ id: string, name: string, path: string, layer: string, kind: string, cron: string | null, at: string | null, expiresAt: string | null, maxRuns: number | null, timeoutMs: number, budgetPerHour: number, nextDueAt: string | null, state: unknown, runningSince: string | null, lastRunAt: string | null, lastDurationMs: number | null, lastError: string | null, lastOutput: string | null, lastSentTo: string | null, runs: number, sends: number, sendsThisHour: number, hourStartedAt: string | null, enabled: boolean, disabledReason: string | null, loadError: string | null, webhookToken: string | null, insertedAt: string, updatedAt: string, projectId: string }> };

export type ListAllWatchesQueryVariables = Exact<{ [key: string]: never; }>;


export type ListAllWatchesQuery = { listAllWatches: { watches: Array<unknown> } };

export type ListCredentialsQueryVariables = Exact<{
  sort?: Array<CredentialSortInput | null | undefined> | CredentialSortInput | null | undefined;
  filter?: CredentialFilterInput | null | undefined;
}>;


export type ListCredentialsQuery = { listCredentials: Array<{ id: string, name: string, label: string | null, kind: string, header: string, scheme: string, allowedHosts: Array<string>, clientId: string | null, authorizeUrl: string | null, tokenUrl: string | null, registrationUrl: string | null, scopes: string | null, pkce: boolean, extraParams: unknown, fixedClient: boolean, redirectUri: string | null, authorizeParams: unknown, deviceFlow: string, expiresAt: string | null, refreshedAt: string | null, lastError: string | null, lastErrorAt: string | null, insertedAt: string, updatedAt: string, hasSecret: boolean | null, hasAccessToken: boolean | null, hasRefreshToken: boolean | null, hasClientSecret: boolean | null, status: string | null }> };

export type CredentialRedirectUriQueryVariables = Exact<{
  origin?: string | null | undefined;
}>;


export type CredentialRedirectUriQuery = { credentialRedirectUri: { uri: string } };

export type ListChromeBrowsersQueryVariables = Exact<{ [key: string]: never; }>;


export type ListChromeBrowsersQuery = { listChromeBrowsers: { browsers: Array<{ status: string, name: string, maxTabs: number, lastSeenAt: string | null, id: string, device: unknown, connected: boolean, approvedAt: string | null, aliases: Array<string>, tabs: Array<{ title: string, threadId: string, tabs: number }> }> } };

export type ChromeAliasesQueryVariables = Exact<{ [key: string]: never; }>;


export type ChromeAliasesQuery = { chromeAliases: { default: string | null, aliases: Array<{ name: string, browsers: Array<string> }> } };

export type ChromeExtensionQueryVariables = Exact<{ [key: string]: never; }>;


export type ChromeExtensionQuery = { chromeExtension: { version: string | null, url: string, minimumChrome: string, built: boolean } };

export type ListDirectoryQueryVariables = Exact<{
  path?: string | null | undefined;
  showHidden?: boolean | null | undefined;
}>;


export type ListDirectoryQuery = { listDirectory: { roots: Array<unknown>, path: string, parent: string | null, git: boolean, entries: Array<unknown> } };

export type KnowledgeDocsQueryVariables = Exact<{ [key: string]: never; }>;


export type KnowledgeDocsQuery = { knowledgeDocs: Array<{ writable: boolean, title: string, tags: Array<string>, summary: string, root: string, path: string, always: boolean }> };

export type KnowledgeReadQueryVariables = Exact<{
  path: string;
}>;


export type KnowledgeReadQuery = { knowledgeRead: { text: string } };

export type AgentSettingsQueryVariables = Exact<{ [key: string]: never; }>;


export type AgentSettingsQuery = { agentSettings: { modelRetries: number, memoryFloorPercent: number, maxDepth: number, maxChildren: number, idleMinutes: number, commandShell: string, commandOomPriority: number, childModel: string | null, childEffort: string | null } };

export type PublicUrlQueryVariables = Exact<{ [key: string]: never; }>;


export type PublicUrlQuery = { publicUrl: { url: string, setting: string | null } };

export type DependenciesQueryVariables = Exact<{ [key: string]: never; }>;


export type DependenciesQuery = { dependencies: { tools: Array<unknown>, os: string, missing: number, installCommand: string | null, checkedAt: string } };

export type FileRulesQueryVariables = Exact<{ [key: string]: never; }>;


export type FileRulesQuery = { fileRules: { watch: string, ignore: string, builtinWatch: Array<string>, builtinIgnore: Array<string> } };

export type SentryStatusQueryVariables = Exact<{ [key: string]: never; }>;


export type SentryStatusQuery = { sentryStatus: { release: string, environment: string, enabled: boolean, dsn: string | null } };

export type UpgradeStatusQueryVariables = Exact<{ [key: string]: never; }>;


export type UpgradeStatusQuery = { upgradeStatus: { target: string | null, stage: string, progress: unknown, notesUrl: string | null, message: string | null, latest: string | null, installed: boolean, hasGithubToken: boolean, error: string | null, current: string, container: boolean, checkedAt: string | null, available: boolean } };

export type GatewayRequestsQueryVariables = Exact<{
  limit?: number | null | undefined;
}>;


export type GatewayRequestsQuery = { gatewayRequests: { requests: Array<unknown>, keep: number } };

export type RecentFaultsQueryVariables = Exact<{ [key: string]: never; }>;


export type RecentFaultsQuery = { recentFaults: { recent: number, faults: Array<unknown> } };

export type RunningCommandsQueryVariables = Exact<{ [key: string]: never; }>;


export type RunningCommandsQuery = { runningCommands: { commands: Array<unknown> } };

export type BrowserSettingsQueryVariables = Exact<{ [key: string]: never; }>;


export type BrowserSettingsQuery = { browserSettings: { available: boolean, allowPrivateNetwork: boolean } };

export type BrowserStatusQueryVariables = Exact<{ [key: string]: never; }>;


export type BrowserStatusQuery = { browserStatus: { version: string, upgradable: boolean, total: number | null, target: string | null, stage: string, source: string | null, received: number, path: string | null, latest: string, installedVersion: string | null, error: string | null } };

export type TlsStatusQueryVariables = Exact<{ [key: string]: never; }>;


export type TlsStatusQuery = { tlsStatus: { url: string | null, total: number | null, toolVersion: string, toolInstalled: boolean, startedAt: string | null, stage: string, serving: boolean, resolvers: Array<string>, redirect: boolean, received: number, provider: string | null, propagationWait: number, propagationCheck: boolean, port: number, httpPort: number | null, finishedAt: string | null, error: string | null, envSet: Array<string>, enabled: boolean, email: string, domains: Array<string>, directory: string, addresses: Array<string>, certificate: { serial: string | null, notBefore: string | null, notAfter: string | null, issuedAt: string | null, domains: Array<string> } | null } };

export type TlsProvidersQueryVariables = Exact<{ [key: string]: never; }>;


export type TlsProvidersQuery = { tlsProviders: { providers: Array<{ url: string | null, name: string, code: string, aliases: Array<string>, credentials: Array<{ name: string, description: string | null }>, additional: Array<{ name: string, description: string | null }> }> } };

export type TlsResolutionQueryVariables = Exact<{
  domains: Array<string> | string;
}>;


export type TlsResolutionQuery = { tlsResolution: { fakeIp: boolean, checkResolvers: Array<string>, addresses: Array<string>, resolution: Array<{ local: Array<string>, here: boolean, fakeIp: boolean, domain: string, addresses: Array<string> }> } };

export type ListProvidersQueryVariables = Exact<{
  sort?: Array<ProviderSortInput | null | undefined> | ProviderSortInput | null | undefined;
  filter?: ProviderFilterInput | null | undefined;
}>;


export type ListProvidersQuery = { listProviders: Array<{ id: string, name: string, slug: string, baseUrl: string, credentialId: string | null, kind: string, supportsHostedWebSearch: boolean, promptCacheKey: boolean | null, requestTimeoutMs: number, streamIdleTimeoutMs: number, maxConcurrentRequests: number | null, lastCheckedAt: string | null, lastError: string | null, lastErrorAt: string | null, insertedAt: string, updatedAt: string, hasApiKey: boolean | null }> };

export type ListModelsQueryVariables = Exact<{
  sort?: Array<ModelSortInput | null | undefined> | ModelSortInput | null | undefined;
  filter?: ModelFilterInput | null | undefined;
}>;


export type ListModelsQuery = { listModels: Array<{ id: string, name: string, slug: string | null, upstreamId: string, contextWindow: number, default: boolean, reasoningLevels: Array<string>, reasoningEffort: string | null, reasoningSummary: string | null, verbosity: string | null, hostedWebSearch: boolean | null, imageGeneration: boolean, maxOutputTokens: number | null, insertedAt: string, updatedAt: string, providerId: string, provider: { id: string, name: string, slug: string, baseUrl: string, credentialId: string | null, kind: string, supportsHostedWebSearch: boolean, promptCacheKey: boolean | null, requestTimeoutMs: number, streamIdleTimeoutMs: number, maxConcurrentRequests: number | null, lastCheckedAt: string | null, lastError: string | null, lastErrorAt: string | null, insertedAt: string, updatedAt: string, hasApiKey: boolean | null } }> };

export type DefaultModelSettingQueryVariables = Exact<{ [key: string]: never; }>;


export type DefaultModelSettingQuery = { defaultModelSetting: { slug: string | null, name: string, kind: string } };

export type ModelAliasesQueryVariables = Exact<{ [key: string]: never; }>;


export type ModelAliasesQuery = { modelAliases: Array<{ name: string, models: Array<string>, label: string, efforts: Array<string | null>, builtin: boolean }> };

export type ListSearchProvidersQueryVariables = Exact<{
  sort?: Array<SearchProviderSortInput | null | undefined> | SearchProviderSortInput | null | undefined;
  filter?: SearchProviderFilterInput | null | undefined;
}>;


export type ListSearchProvidersQuery = { listSearchProviders: Array<{ id: string, name: string, slug: string, kind: string, baseUrl: string, default: boolean, hasApiKey: boolean | null }> };

export type ListPresetsQueryVariables = Exact<{ [key: string]: never; }>;


export type ListPresetsQuery = { listPresets: Array<{ supportsHostedWebSearch: boolean, slug: string, providerId: string | null, name: string, models: Array<unknown>, kind: string, keyUrl: string, keyEnv: string, installed: boolean, docsUrl: string, credential: boolean, baseUrl: string }> };

export type ListProjectsQueryVariables = Exact<{
  sort?: Array<ProjectSortInput | null | undefined> | ProjectSortInput | null | undefined;
  filter?: ProjectFilterInput | null | undefined;
}>;


export type ListProjectsQuery = { listProjects: Array<{ id: string, name: string, slug: string, description: string | null, rootPath: string, webSearch: boolean, trustLocalAgent: boolean, agentSettings: unknown, fileRules: unknown, archivedAt: string | null, insertedAt: string, updatedAt: string, modelId: string | null }> };

export type ListAllProjectsQueryVariables = Exact<{
  sort?: Array<ProjectSortInput | null | undefined> | ProjectSortInput | null | undefined;
  filter?: ProjectFilterInput | null | undefined;
}>;


export type ListAllProjectsQuery = { listAllProjects: Array<{ id: string, name: string, slug: string, description: string | null, rootPath: string, webSearch: boolean, trustLocalAgent: boolean, agentSettings: unknown, fileRules: unknown, archivedAt: string | null, insertedAt: string, updatedAt: string, modelId: string | null }> };

export type GetProjectQueryVariables = Exact<{
  filter?: ProjectFilterInput | null | undefined;
  slug: string;
}>;


export type GetProjectQuery = { getProject: { id: string, name: string, slug: string, description: string | null, rootPath: string, webSearch: boolean, trustLocalAgent: boolean, agentSettings: unknown, fileRules: unknown, archivedAt: string | null, insertedAt: string, updatedAt: string, modelId: string | null } | null };

export type GitInfoQueryVariables = Exact<{
  id: string | number;
}>;


export type GitInfoQuery = { gitInfo: { repository: boolean, lfs: boolean, head: string | null, clean: boolean | null, changes: number } };

export type SearchFilesQueryVariables = Exact<{
  id: string | number;
  query: string;
}>;


export type SearchFilesQuery = { searchFiles: Array<{ score: number, root: string, path: string, matchType: string, indices: Array<number> | null, fileName: string }> };

export type AgentDefinitionQueryVariables = Exact<{
  id: string | number;
}>;


export type AgentDefinitionQuery = { agentDefinition: { trusted: boolean, present: boolean, plugs: Array<string>, model: string | null, localFiles: Array<string>, files: Array<string>, errors: Array<string>, effort: string | null, dir: string, agents: Array<unknown>, settings: { modelRetries: number | null, memoryFloorPercent: number | null, maxDepth: number | null, maxChildren: number | null, idleMinutes: number | null, commandOomPriority: number | null, childModel: string | null, childEffort: string | null }, overrides: { modelRetries: number | null, memoryFloorPercent: number | null, maxDepth: number | null, maxChildren: number | null, idleMinutes: number | null, commandOomPriority: number | null, childModel: string | null, childEffort: string | null }, browser: { state: string, maxTabs: number, browser: string | null, alias: string | null } | null } };

export type ListThreadsQueryVariables = Exact<{
  sort?: Array<ThreadSortInput | null | undefined> | ThreadSortInput | null | undefined;
  filter?: ThreadFilterInput | null | undefined;
  projectId: string | number;
}>;


export type ListThreadsQuery = { listThreads: Array<{ id: string, kernelThreadId: string, title: string | null, preview: string | null, handle: string | null, onDuty: boolean, cwd: string, modelSlug: string | null, reasoningEffort: string | null, webSearch: boolean, agentPath: string | null, status: string, lastActivityAt: string | null, insertedAt: string, updatedAt: string, projectId: string, parentThreadId: string | null }> };

export type GetThreadQueryVariables = Exact<{
  filter?: ThreadFilterInput | null | undefined;
  id: string | number;
}>;


export type GetThreadQuery = { getThread: { id: string, kernelThreadId: string, title: string | null, preview: string | null, handle: string | null, onDuty: boolean, cwd: string, modelSlug: string | null, reasoningEffort: string | null, webSearch: boolean, agentPath: string | null, status: string, lastActivityAt: string | null, insertedAt: string, updatedAt: string, projectId: string, parentThreadId: string | null } | null };

export type ListSubagentsQueryVariables = Exact<{
  sort?: Array<ThreadSortInput | null | undefined> | ThreadSortInput | null | undefined;
  filter?: ThreadFilterInput | null | undefined;
  parentThreadId: string | number;
}>;


export type ListSubagentsQuery = { listSubagents: Array<{ id: string, kernelThreadId: string, title: string | null, preview: string | null, handle: string | null, onDuty: boolean, cwd: string, modelSlug: string | null, reasoningEffort: string | null, webSearch: boolean, agentPath: string | null, status: string, lastActivityAt: string | null, insertedAt: string, updatedAt: string, projectId: string, parentThreadId: string | null }> };

export type ListRunningThreadsQueryVariables = Exact<{ [key: string]: never; }>;


export type ListRunningThreadsQuery = { listRunningThreads: { threads: Array<unknown>, finished: Array<unknown> } };

export type ListRecentThreadsQueryVariables = Exact<{
  limit?: number | null | undefined;
}>;


export type ListRecentThreadsQuery = { listRecentThreads: { threads: Array<unknown> } };

export type ProjectJobsQueryVariables = Exact<{
  projectId: string | number;
}>;


export type ProjectJobsQuery = { projectJobs: { jobs: Array<unknown> } };

export type DirectoryQueryVariables = Exact<{
  projectId: string | number;
  scope?: string | null | undefined;
}>;


export type DirectoryQuery = { directory: { sessions: Array<unknown> } };

export type ListFilesQueryVariables = Exact<{
  projectId: string | number;
  path: string;
}>;


export type ListFilesQuery = { listFiles: Array<{ size: number, path: string, name: string, kind: string }> };

export type ReadFileQueryVariables = Exact<{
  projectId: string | number;
  path: string;
}>;


export type ReadFileQuery = { readFile: { truncated: boolean, size: number, path: string, content: string | null, binary: boolean } };

export type IgnoredPathsQueryVariables = Exact<{
  projectId: string | number;
}>;


export type IgnoredPathsQuery = { ignoredPaths: Array<string> };

export type GitChangesQueryVariables = Exact<{
  projectId: string | number;
}>;


export type GitChangesQuery = { gitChanges: { repository: boolean, remotes: Array<unknown>, merging: boolean, lfs: boolean, ignored: Array<string>, head: string | null, changes: Array<unknown>, branch: string | null, behind: number | null, ahead: number | null } };

export type GitFileDiffQueryVariables = Exact<{
  projectId: string | number;
  path: string;
}>;


export type GitFileDiffQuery = { gitFileDiff: { diff: string, binary: boolean } };

export type GitLogQueryVariables = Exact<{
  projectId: string | number;
  limit?: number | null | undefined;
  skip?: number | null | undefined;
}>;


export type GitLogQuery = { gitLog: Array<{ subject: string, sha: string, email: string, author: string, at: string }> };

export type GitShowQueryVariables = Exact<{
  projectId: string | number;
  sha: string;
}>;


export type GitShowQuery = { gitShow: { subject: string, sha: string, parents: Array<string>, files: Array<unknown>, email: string, body: string, author: string, at: string } };

export type GitCommitFileDiffQueryVariables = Exact<{
  projectId: string | number;
  sha: string;
  path: string;
}>;


export type GitCommitFileDiffQuery = { gitCommitFileDiff: { diff: string, binary: boolean } };

export type GitFileVersionsQueryVariables = Exact<{
  projectId: string | number;
  sha?: string | null | undefined;
  path: string;
}>;


export type GitFileVersionsQuery = { gitFileVersions: { binary: boolean, before: string | null, after: string | null } };

export type GitBranchesQueryVariables = Exact<{
  projectId: string | number;
}>;


export type GitBranchesQuery = { gitBranches: { stashes: Array<unknown>, current: string | null, branches: Array<unknown> } };

export type ListTurnsQueryVariables = Exact<{
  sort?: Array<TurnSortInput | null | undefined> | TurnSortInput | null | undefined;
  filter?: TurnFilterInput | null | undefined;
  threadId: string | number;
  includeReverted?: boolean | null | undefined;
}>;


export type ListTurnsQuery = { listTurns: Array<{ id: string, kernelTurnId: string, userText: string | null, modelSlug: string | null, reasoningEffort: string | null, status: string, startedAt: string, completedAt: string | null, error: string | null, usage: unknown, insertedAt: string, updatedAt: string, threadId: string }> };

export type SwitchWatchMutationVariables = Exact<{
  input: SwitchWatchInput;
}>;


export type SwitchWatchMutation = { switchWatch: { id: string, name: string, path: string, layer: string, kind: string, cron: string | null, at: string | null, expiresAt: string | null, maxRuns: number | null, timeoutMs: number, budgetPerHour: number, nextDueAt: string | null, state: unknown, runningSince: string | null, lastRunAt: string | null, lastDurationMs: number | null, lastError: string | null, lastOutput: string | null, lastSentTo: string | null, runs: number, sends: number, sendsThisHour: number, hourStartedAt: string | null, enabled: boolean, disabledReason: string | null, loadError: string | null, webhookToken: string | null, insertedAt: string, updatedAt: string, projectId: string } };

export type DryRunWatchMutationVariables = Exact<{
  input: DryRunWatchInput;
}>;


export type DryRunWatchMutation = { dryRunWatch: { sends: Array<string>, result: string, ok: boolean, log: Array<string> } };

export type DeleteWatchMutationVariables = Exact<{
  input: DeleteWatchInput;
}>;


export type DeleteWatchMutation = { deleteWatch: boolean };

export type CreateCredentialApiKeyMutationVariables = Exact<{
  input: CreateCredentialApiKeyInput;
}>;


export type CreateCredentialApiKeyMutation = { createCredentialApiKey: { result: { id: string, name: string, label: string | null, kind: string, header: string, scheme: string, allowedHosts: Array<string>, clientId: string | null, authorizeUrl: string | null, tokenUrl: string | null, registrationUrl: string | null, scopes: string | null, pkce: boolean, extraParams: unknown, fixedClient: boolean, redirectUri: string | null, authorizeParams: unknown, deviceFlow: string, expiresAt: string | null, refreshedAt: string | null, lastError: string | null, lastErrorAt: string | null, insertedAt: string, updatedAt: string, hasSecret: boolean | null, hasAccessToken: boolean | null, hasRefreshToken: boolean | null, hasClientSecret: boolean | null, status: string | null } | null } | null };

export type CreateCredentialOauth2MutationVariables = Exact<{
  input: CreateCredentialOauth2Input;
}>;


export type CreateCredentialOauth2Mutation = { createCredentialOauth2: { result: { id: string, name: string, label: string | null, kind: string, header: string, scheme: string, allowedHosts: Array<string>, clientId: string | null, authorizeUrl: string | null, tokenUrl: string | null, registrationUrl: string | null, scopes: string | null, pkce: boolean, extraParams: unknown, fixedClient: boolean, redirectUri: string | null, authorizeParams: unknown, deviceFlow: string, expiresAt: string | null, refreshedAt: string | null, lastError: string | null, lastErrorAt: string | null, insertedAt: string, updatedAt: string, hasSecret: boolean | null, hasAccessToken: boolean | null, hasRefreshToken: boolean | null, hasClientSecret: boolean | null, status: string | null } | null } | null };

export type UpdateCredentialMutationVariables = Exact<{
  id: string | number;
  input?: UpdateCredentialInput | null | undefined;
}>;


export type UpdateCredentialMutation = { updateCredential: { result: { id: string, name: string, label: string | null, kind: string, header: string, scheme: string, allowedHosts: Array<string>, clientId: string | null, authorizeUrl: string | null, tokenUrl: string | null, registrationUrl: string | null, scopes: string | null, pkce: boolean, extraParams: unknown, fixedClient: boolean, redirectUri: string | null, authorizeParams: unknown, deviceFlow: string, expiresAt: string | null, refreshedAt: string | null, lastError: string | null, lastErrorAt: string | null, insertedAt: string, updatedAt: string, hasSecret: boolean | null, hasAccessToken: boolean | null, hasRefreshToken: boolean | null, hasClientSecret: boolean | null, status: string | null } | null } | null };

export type DeleteCredentialMutationVariables = Exact<{
  id: string | number;
}>;


export type DeleteCredentialMutation = { deleteCredential: { result: { id: string, name: string, label: string | null, kind: string, header: string, scheme: string, allowedHosts: Array<string>, clientId: string | null, authorizeUrl: string | null, tokenUrl: string | null, registrationUrl: string | null, scopes: string | null, pkce: boolean, extraParams: unknown, fixedClient: boolean, redirectUri: string | null, authorizeParams: unknown, deviceFlow: string, expiresAt: string | null, refreshedAt: string | null, lastError: string | null, lastErrorAt: string | null, insertedAt: string, updatedAt: string, hasSecret: boolean | null, hasAccessToken: boolean | null, hasRefreshToken: boolean | null, hasClientSecret: boolean | null, status: string | null } | null } | null };

export type CredentialLoginUrlMutationVariables = Exact<{
  input: CredentialLoginUrlInput;
}>;


export type CredentialLoginUrlMutation = { credentialLoginUrl: { url: string, redirectUri: string, loopback: boolean } };

export type RefreshCredentialMutationVariables = Exact<{
  input: RefreshCredentialInput;
}>;


export type RefreshCredentialMutation = { refreshCredential: { id: string, name: string, label: string | null, kind: string, header: string, scheme: string, allowedHosts: Array<string>, clientId: string | null, authorizeUrl: string | null, tokenUrl: string | null, registrationUrl: string | null, scopes: string | null, pkce: boolean, extraParams: unknown, fixedClient: boolean, redirectUri: string | null, authorizeParams: unknown, deviceFlow: string, expiresAt: string | null, refreshedAt: string | null, lastError: string | null, lastErrorAt: string | null, insertedAt: string, updatedAt: string, hasSecret: boolean | null, hasAccessToken: boolean | null, hasRefreshToken: boolean | null, hasClientSecret: boolean | null, status: string | null } };

export type CredentialCompleteUrlMutationVariables = Exact<{
  input: CredentialCompleteUrlInput;
}>;


export type CredentialCompleteUrlMutation = { credentialCompleteUrl: { id: string, name: string, label: string | null, kind: string, header: string, scheme: string, allowedHosts: Array<string>, clientId: string | null, authorizeUrl: string | null, tokenUrl: string | null, registrationUrl: string | null, scopes: string | null, pkce: boolean, extraParams: unknown, fixedClient: boolean, redirectUri: string | null, authorizeParams: unknown, deviceFlow: string, expiresAt: string | null, refreshedAt: string | null, lastError: string | null, lastErrorAt: string | null, insertedAt: string, updatedAt: string, hasSecret: boolean | null, hasAccessToken: boolean | null, hasRefreshToken: boolean | null, hasClientSecret: boolean | null, status: string | null } };

export type CredentialDeviceBeginMutationVariables = Exact<{
  input: CredentialDeviceBeginInput;
}>;


export type CredentialDeviceBeginMutation = { credentialDeviceBegin: { verificationUrl: string, userCode: string, state: string, interval: number } };

export type CredentialDevicePollMutationVariables = Exact<{
  input: CredentialDevicePollInput;
}>;


export type CredentialDevicePollMutation = { credentialDevicePoll: { status: string, message: string | null } };

export type ApproveChromeBrowserMutationVariables = Exact<{
  input: ApproveChromeBrowserInput;
}>;


export type ApproveChromeBrowserMutation = { approveChromeBrowser: { ok: boolean } };

export type RejectChromeBrowserMutationVariables = Exact<{
  input: RejectChromeBrowserInput;
}>;


export type RejectChromeBrowserMutation = { rejectChromeBrowser: { ok: boolean } };

export type RevokeChromeBrowserMutationVariables = Exact<{
  input: RevokeChromeBrowserInput;
}>;


export type RevokeChromeBrowserMutation = { revokeChromeBrowser: { ok: boolean } };

export type RenameChromeBrowserMutationVariables = Exact<{
  input: RenameChromeBrowserInput;
}>;


export type RenameChromeBrowserMutation = { renameChromeBrowser: { ok: boolean } };

export type SetChromeBrowserMaxTabsMutationVariables = Exact<{
  input: SetChromeBrowserMaxTabsInput;
}>;


export type SetChromeBrowserMaxTabsMutation = { setChromeBrowserMaxTabs: { ok: boolean } };

export type SetChromeAliasMutationVariables = Exact<{
  input: SetChromeAliasInput;
}>;


export type SetChromeAliasMutation = { setChromeAlias: { default: string | null, aliases: Array<{ name: string, browsers: Array<string> }> } };

export type DeleteChromeAliasMutationVariables = Exact<{
  input: DeleteChromeAliasInput;
}>;


export type DeleteChromeAliasMutation = { deleteChromeAlias: { default: string | null, aliases: Array<{ name: string, browsers: Array<string> }> } };

export type SetChromeDefaultAliasMutationVariables = Exact<{
  input?: SetChromeDefaultAliasInput | null | undefined;
}>;


export type SetChromeDefaultAliasMutation = { setChromeDefaultAlias: { default: string | null, aliases: Array<{ name: string, browsers: Array<string> }> } };

export type CreateDirectoryMutationVariables = Exact<{
  input: CreateDirectoryInput;
}>;


export type CreateDirectoryMutation = { createDirectory: { path: string, name: string, git: boolean } };

export type KnowledgeWriteMutationVariables = Exact<{
  input: KnowledgeWriteInput;
}>;


export type KnowledgeWriteMutation = { knowledgeWrite: boolean };

export type KnowledgeDeleteMutationVariables = Exact<{
  input: KnowledgeDeleteInput;
}>;


export type KnowledgeDeleteMutation = { knowledgeDelete: boolean };

export type SetAgentSettingsMutationVariables = Exact<{
  input?: SetAgentSettingsInput | null | undefined;
}>;


export type SetAgentSettingsMutation = { setAgentSettings: { modelRetries: number, memoryFloorPercent: number, maxDepth: number, maxChildren: number, idleMinutes: number, commandShell: string, commandOomPriority: number, childModel: string | null, childEffort: string | null } };

export type CheckDependenciesMutationVariables = Exact<{ [key: string]: never; }>;


export type CheckDependenciesMutation = { checkDependencies: { tools: Array<unknown>, os: string, missing: number, installCommand: string | null, checkedAt: string } };

export type SetPublicUrlMutationVariables = Exact<{
  input: SetPublicUrlInput;
}>;


export type SetPublicUrlMutation = { setPublicUrl: { url: string, setting: string | null } };

export type SetFileRulesMutationVariables = Exact<{
  input?: SetFileRulesInput | null | undefined;
}>;


export type SetFileRulesMutation = { setFileRules: { watch: string, ignore: string, builtinWatch: Array<string>, builtinIgnore: Array<string> } };

export type SetSentryDsnMutationVariables = Exact<{
  input: SetSentryDsnInput;
}>;


export type SetSentryDsnMutation = { setSentryDsn: { release: string, environment: string, enabled: boolean, dsn: string | null } };

export type SentryTestMutationVariables = Exact<{ [key: string]: never; }>;


export type SentryTestMutation = { sentryTest: { ok: boolean, message: string } };

export type UpgradeCheckMutationVariables = Exact<{ [key: string]: never; }>;


export type UpgradeCheckMutation = { upgradeCheck: { target: string | null, stage: string, progress: unknown, notesUrl: string | null, message: string | null, latest: string | null, installed: boolean, hasGithubToken: boolean, error: string | null, current: string, container: boolean, checkedAt: string | null, available: boolean } };

export type UpgradeApplyMutationVariables = Exact<{ [key: string]: never; }>;


export type UpgradeApplyMutation = { upgradeApply: { target: string | null, stage: string, progress: unknown, notesUrl: string | null, message: string | null, latest: string | null, installed: boolean, hasGithubToken: boolean, error: string | null, current: string, container: boolean, checkedAt: string | null, available: boolean } };

export type SetGithubTokenMutationVariables = Exact<{
  input?: SetGithubTokenInput | null | undefined;
}>;


export type SetGithubTokenMutation = { setGithubToken: { target: string | null, stage: string, progress: unknown, notesUrl: string | null, message: string | null, latest: string | null, installed: boolean, hasGithubToken: boolean, error: string | null, current: string, container: boolean, checkedAt: string | null, available: boolean } };

export type KillCommandMutationVariables = Exact<{
  input: KillCommandInput;
}>;


export type KillCommandMutation = { killCommand: { ok: boolean } };

export type BrowserInstallMutationVariables = Exact<{ [key: string]: never; }>;


export type BrowserInstallMutation = { browserInstall: { version: string, upgradable: boolean, total: number | null, target: string | null, stage: string, source: string | null, received: number, path: string | null, latest: string, installedVersion: string | null, error: string | null } };

export type SetBrowserPrivateNetworkMutationVariables = Exact<{
  input: SetBrowserPrivateNetworkInput;
}>;


export type SetBrowserPrivateNetworkMutation = { setBrowserPrivateNetwork: { available: boolean, allowPrivateNetwork: boolean } };

export type SetTlsMutationVariables = Exact<{
  input?: SetTlsInput | null | undefined;
}>;


export type SetTlsMutation = { setTls: { url: string | null, total: number | null, toolVersion: string, toolInstalled: boolean, startedAt: string | null, stage: string, serving: boolean, resolvers: Array<string>, redirect: boolean, received: number, provider: string | null, propagationWait: number, propagationCheck: boolean, port: number, httpPort: number | null, finishedAt: string | null, error: string | null, envSet: Array<string>, enabled: boolean, email: string, domains: Array<string>, directory: string, addresses: Array<string>, certificate: { serial: string | null, notBefore: string | null, notAfter: string | null, issuedAt: string | null, domains: Array<string> } | null } };

export type TlsIssueMutationVariables = Exact<{ [key: string]: never; }>;


export type TlsIssueMutation = { tlsIssue: { url: string | null, total: number | null, toolVersion: string, toolInstalled: boolean, startedAt: string | null, stage: string, serving: boolean, resolvers: Array<string>, redirect: boolean, received: number, provider: string | null, propagationWait: number, propagationCheck: boolean, port: number, httpPort: number | null, finishedAt: string | null, error: string | null, envSet: Array<string>, enabled: boolean, email: string, domains: Array<string>, directory: string, addresses: Array<string>, certificate: { serial: string | null, notBefore: string | null, notAfter: string | null, issuedAt: string | null, domains: Array<string> } | null } };

export type TlsDisableMutationVariables = Exact<{ [key: string]: never; }>;


export type TlsDisableMutation = { tlsDisable: { url: string | null, total: number | null, toolVersion: string, toolInstalled: boolean, startedAt: string | null, stage: string, serving: boolean, resolvers: Array<string>, redirect: boolean, received: number, provider: string | null, propagationWait: number, propagationCheck: boolean, port: number, httpPort: number | null, finishedAt: string | null, error: string | null, envSet: Array<string>, enabled: boolean, email: string, domains: Array<string>, directory: string, addresses: Array<string>, certificate: { serial: string | null, notBefore: string | null, notAfter: string | null, issuedAt: string | null, domains: Array<string> } | null } };

export type CreateProviderMutationVariables = Exact<{
  input: CreateProviderInput;
}>;


export type CreateProviderMutation = { createProvider: { result: { id: string, name: string, slug: string, baseUrl: string, credentialId: string | null, kind: string, supportsHostedWebSearch: boolean, promptCacheKey: boolean | null, requestTimeoutMs: number, streamIdleTimeoutMs: number, maxConcurrentRequests: number | null, lastCheckedAt: string | null, lastError: string | null, lastErrorAt: string | null, insertedAt: string, updatedAt: string, hasApiKey: boolean | null } | null } | null };

export type UpdateProviderMutationVariables = Exact<{
  id: string | number;
  input?: UpdateProviderInput | null | undefined;
}>;


export type UpdateProviderMutation = { updateProvider: { result: { id: string, name: string, slug: string, baseUrl: string, credentialId: string | null, kind: string, supportsHostedWebSearch: boolean, promptCacheKey: boolean | null, requestTimeoutMs: number, streamIdleTimeoutMs: number, maxConcurrentRequests: number | null, lastCheckedAt: string | null, lastError: string | null, lastErrorAt: string | null, insertedAt: string, updatedAt: string, hasApiKey: boolean | null } | null } | null };

export type DeleteProviderMutationVariables = Exact<{
  id: string | number;
}>;


export type DeleteProviderMutation = { deleteProvider: { result: { id: string, name: string, slug: string, baseUrl: string, credentialId: string | null, kind: string, supportsHostedWebSearch: boolean, promptCacheKey: boolean | null, requestTimeoutMs: number, streamIdleTimeoutMs: number, maxConcurrentRequests: number | null, lastCheckedAt: string | null, lastError: string | null, lastErrorAt: string | null, insertedAt: string, updatedAt: string, hasApiKey: boolean | null } | null } | null };

export type DiscoverModelsMutationVariables = Exact<{
  input: DiscoverModelsInput;
}>;


export type DiscoverModelsMutation = { discoverModels: { ok: boolean, models: Array<unknown>, error: string | null } };

export type CreateModelMutationVariables = Exact<{
  input: CreateModelInput;
}>;


export type CreateModelMutation = { createModel: { result: { id: string, name: string, slug: string | null, upstreamId: string, contextWindow: number, default: boolean, reasoningLevels: Array<string>, reasoningEffort: string | null, reasoningSummary: string | null, verbosity: string | null, hostedWebSearch: boolean | null, imageGeneration: boolean, maxOutputTokens: number | null, insertedAt: string, updatedAt: string, providerId: string } | null } | null };

export type UpdateModelMutationVariables = Exact<{
  id: string | number;
  input?: UpdateModelInput | null | undefined;
}>;


export type UpdateModelMutation = { updateModel: { result: { id: string, name: string, slug: string | null, upstreamId: string, contextWindow: number, default: boolean, reasoningLevels: Array<string>, reasoningEffort: string | null, reasoningSummary: string | null, verbosity: string | null, hostedWebSearch: boolean | null, imageGeneration: boolean, maxOutputTokens: number | null, insertedAt: string, updatedAt: string, providerId: string } | null } | null };

export type MakeDefaultModelMutationVariables = Exact<{
  id: string | number;
}>;


export type MakeDefaultModelMutation = { makeDefaultModel: { result: { id: string, name: string, slug: string | null, upstreamId: string, contextWindow: number, default: boolean, reasoningLevels: Array<string>, reasoningEffort: string | null, reasoningSummary: string | null, verbosity: string | null, hostedWebSearch: boolean | null, imageGeneration: boolean, maxOutputTokens: number | null, insertedAt: string, updatedAt: string, providerId: string } | null } | null };

export type SetDefaultModelMutationVariables = Exact<{
  input: SetDefaultModelInput;
}>;


export type SetDefaultModelMutation = { setDefaultModel: { slug: string | null, name: string, kind: string } };

export type CheckModelMutationVariables = Exact<{
  input: CheckModelInput;
}>;


export type CheckModelMutation = { checkModel: { ok: boolean, latencyMs: number | null, error: string | null } };

export type SetModelAliasMutationVariables = Exact<{
  input: SetModelAliasInput;
}>;


export type SetModelAliasMutation = { setModelAlias: { name: string, models: Array<string>, label: string, efforts: Array<string | null>, builtin: boolean } };

export type DeleteModelAliasMutationVariables = Exact<{
  input: DeleteModelAliasInput;
}>;


export type DeleteModelAliasMutation = { deleteModelAlias: boolean };

export type DeleteModelMutationVariables = Exact<{
  id: string | number;
}>;


export type DeleteModelMutation = { deleteModel: { result: { id: string, name: string, slug: string | null, upstreamId: string, contextWindow: number, default: boolean, reasoningLevels: Array<string>, reasoningEffort: string | null, reasoningSummary: string | null, verbosity: string | null, hostedWebSearch: boolean | null, imageGeneration: boolean, maxOutputTokens: number | null, insertedAt: string, updatedAt: string, providerId: string } | null } | null };

export type UpdateSearchProviderMutationVariables = Exact<{
  id: string | number;
  input?: UpdateSearchProviderInput | null | undefined;
}>;


export type UpdateSearchProviderMutation = { updateSearchProvider: { result: { id: string, name: string, slug: string, kind: string, baseUrl: string, default: boolean, hasApiKey: boolean | null } | null } | null };

export type ApplyPresetMutationVariables = Exact<{
  input: ApplyPresetInput;
}>;


export type ApplyPresetMutation = { applyPreset: { providerId: string, modelIds: Array<string>, credentialId: string | null } };

export type CreateProjectMutationVariables = Exact<{
  input: CreateProjectInput;
}>;


export type CreateProjectMutation = { createProject: { result: { id: string, name: string, slug: string, description: string | null, rootPath: string, webSearch: boolean, trustLocalAgent: boolean, agentSettings: unknown, fileRules: unknown, archivedAt: string | null, insertedAt: string, updatedAt: string, modelId: string | null } | null } | null };

export type UpdateProjectMutationVariables = Exact<{
  id: string | number;
  input?: UpdateProjectInput | null | undefined;
}>;


export type UpdateProjectMutation = { updateProject: { result: { id: string, name: string, slug: string, description: string | null, rootPath: string, webSearch: boolean, trustLocalAgent: boolean, agentSettings: unknown, fileRules: unknown, archivedAt: string | null, insertedAt: string, updatedAt: string, modelId: string | null } | null } | null };

export type ArchiveProjectMutationVariables = Exact<{
  id: string | number;
}>;


export type ArchiveProjectMutation = { archiveProject: { result: { id: string, name: string, slug: string, description: string | null, rootPath: string, webSearch: boolean, trustLocalAgent: boolean, agentSettings: unknown, fileRules: unknown, archivedAt: string | null, insertedAt: string, updatedAt: string, modelId: string | null } | null } | null };

export type DeleteProjectMutationVariables = Exact<{
  id: string | number;
  input?: DeleteProjectInput | null | undefined;
}>;


export type DeleteProjectMutation = { deleteProject: { result: { id: string, name: string, slug: string, description: string | null, rootPath: string, webSearch: boolean, trustLocalAgent: boolean, agentSettings: unknown, fileRules: unknown, archivedAt: string | null, insertedAt: string, updatedAt: string, modelId: string | null } | null } | null };

export type PromoteLocalMutationVariables = Exact<{
  input: PromoteLocalInput;
}>;


export type PromoteLocalMutation = { promoteLocal: { path: string } };

export type InitGitMutationVariables = Exact<{
  input: InitGitInput;
}>;


export type InitGitMutation = { initGit: { repository: boolean, lfs: boolean, head: string | null, clean: boolean | null, changes: number } };

export type StartThreadMutationVariables = Exact<{
  input: StartThreadInput;
}>;


export type StartThreadMutation = { startThread: { id: string, kernelThreadId: string, title: string | null, preview: string | null, handle: string | null, onDuty: boolean, cwd: string, modelSlug: string | null, reasoningEffort: string | null, webSearch: boolean, agentPath: string | null, status: string, lastActivityAt: string | null, insertedAt: string, updatedAt: string, projectId: string, parentThreadId: string | null } };

export type SendMessageMutationVariables = Exact<{
  input: SendMessageInput;
}>;


export type SendMessageMutation = { sendMessage: { id: string, kernelTurnId: string, userText: string | null, modelSlug: string | null, reasoningEffort: string | null, status: string, startedAt: string, completedAt: string | null, error: string | null, usage: unknown, insertedAt: string, updatedAt: string, threadId: string } };

export type InterruptTurnMutationVariables = Exact<{
  input: InterruptTurnInput;
}>;


export type InterruptTurnMutation = { interruptTurn: boolean };

export type SteerTurnMutationVariables = Exact<{
  input: SteerTurnInput;
}>;


export type SteerTurnMutation = { steerTurn: { kernelTurnId: string } };

export type RetractTurnMutationVariables = Exact<{
  input: RetractTurnInput;
}>;


export type RetractTurnMutation = { retractTurn: { text: string } };

export type ReleaseWaitingMutationVariables = Exact<{
  input: ReleaseWaitingInput;
}>;


export type ReleaseWaitingMutation = { releaseWaiting: boolean };

export type CompactThreadMutationVariables = Exact<{
  input: CompactThreadInput;
}>;


export type CompactThreadMutation = { compactThread: boolean };

export type AnswerRequestMutationVariables = Exact<{
  input: AnswerRequestInput;
}>;


export type AnswerRequestMutation = { answerRequest: boolean };

export type SetGoalMutationVariables = Exact<{
  input: SetGoalInput;
}>;


export type SetGoalMutation = { setGoal: { tokensUsed: number, tokenBudget: number | null, timeUsedSeconds: number, status: string, objective: string } };

export type ClearGoalMutationVariables = Exact<{
  input: ClearGoalInput;
}>;


export type ClearGoalMutation = { clearGoal: { cleared: boolean } };

export type RenameThreadMutationVariables = Exact<{
  id: string | number;
  input?: RenameThreadInput | null | undefined;
}>;


export type RenameThreadMutation = { renameThread: { result: { id: string, kernelThreadId: string, title: string | null, preview: string | null, handle: string | null, onDuty: boolean, cwd: string, modelSlug: string | null, reasoningEffort: string | null, webSearch: boolean, agentPath: string | null, status: string, lastActivityAt: string | null, insertedAt: string, updatedAt: string, projectId: string, parentThreadId: string | null } | null } | null };

export type SetThreadHandleMutationVariables = Exact<{
  input: SetThreadHandleInput;
}>;


export type SetThreadHandleMutation = { setThreadHandle: { id: string, kernelThreadId: string, title: string | null, preview: string | null, handle: string | null, onDuty: boolean, cwd: string, modelSlug: string | null, reasoningEffort: string | null, webSearch: boolean, agentPath: string | null, status: string, lastActivityAt: string | null, insertedAt: string, updatedAt: string, projectId: string, parentThreadId: string | null } };

export type SetThreadOnDutyMutationVariables = Exact<{
  input: SetThreadOnDutyInput;
}>;


export type SetThreadOnDutyMutation = { setThreadOnDuty: { id: string, kernelThreadId: string, title: string | null, preview: string | null, handle: string | null, onDuty: boolean, cwd: string, modelSlug: string | null, reasoningEffort: string | null, webSearch: boolean, agentPath: string | null, status: string, lastActivityAt: string | null, insertedAt: string, updatedAt: string, projectId: string, parentThreadId: string | null } };

export type ArchiveThreadMutationVariables = Exact<{
  id: string | number;
}>;


export type ArchiveThreadMutation = { archiveThread: { result: { id: string, kernelThreadId: string, title: string | null, preview: string | null, handle: string | null, onDuty: boolean, cwd: string, modelSlug: string | null, reasoningEffort: string | null, webSearch: boolean, agentPath: string | null, status: string, lastActivityAt: string | null, insertedAt: string, updatedAt: string, projectId: string, parentThreadId: string | null } | null } | null };

export type DeleteThreadMutationVariables = Exact<{
  input: DeleteThreadInput;
}>;


export type DeleteThreadMutation = { deleteThread: boolean };

export type WriteFileMutationVariables = Exact<{
  input: WriteFileInput;
}>;


export type WriteFileMutation = { writeFile: boolean };

export type CreateEntryMutationVariables = Exact<{
  input: CreateEntryInput;
}>;


export type CreateEntryMutation = { createEntry: { size: number, path: string, name: string, kind: string } };

export type RenameEntryMutationVariables = Exact<{
  input: RenameEntryInput;
}>;


export type RenameEntryMutation = { renameEntry: { size: number, path: string, name: string, kind: string } };

export type DeleteEntryMutationVariables = Exact<{
  input: DeleteEntryInput;
}>;


export type DeleteEntryMutation = { deleteEntry: boolean };

export type GitCommitMutationVariables = Exact<{
  input: GitCommitInput;
}>;


export type GitCommitMutation = { gitCommit: { sha: string } };

export type GitDiscardMutationVariables = Exact<{
  input: GitDiscardInput;
}>;


export type GitDiscardMutation = { gitDiscard: boolean };

export type GitUndoCommitMutationVariables = Exact<{
  input: GitUndoCommitInput;
}>;


export type GitUndoCommitMutation = { gitUndoCommit: { sha: string } };

export type GitAbortMergeMutationVariables = Exact<{
  input: GitAbortMergeInput;
}>;


export type GitAbortMergeMutation = { gitAbortMerge: boolean };

export type GitCreateBranchMutationVariables = Exact<{
  input: GitCreateBranchInput;
}>;


export type GitCreateBranchMutation = { gitCreateBranch: boolean };

export type GitSwitchMutationVariables = Exact<{
  input: GitSwitchInput;
}>;


export type GitSwitchMutation = { gitSwitch: boolean };

export type GitDeleteBranchMutationVariables = Exact<{
  input: GitDeleteBranchInput;
}>;


export type GitDeleteBranchMutation = { gitDeleteBranch: boolean };

export type GitStashPopMutationVariables = Exact<{
  input: GitStashPopInput;
}>;


export type GitStashPopMutation = { gitStashPop: boolean };

export type GitSetRemoteMutationVariables = Exact<{
  input: GitSetRemoteInput;
}>;


export type GitSetRemoteMutation = { gitSetRemote: boolean };

export type GitFetchMutationVariables = Exact<{
  input: GitFetchInput;
}>;


export type GitFetchMutation = { gitFetch: boolean };

export type GitPullMutationVariables = Exact<{
  input: GitPullInput;
}>;


export type GitPullMutation = { gitPull: boolean };

export type GitPushMutationVariables = Exact<{
  input: GitPushInput;
}>;


export type GitPushMutation = { gitPush: boolean };

export class TypedDocumentString<TResult, TVariables>
  extends String
  implements DocumentTypeDecoration<TResult, TVariables>
{
  __apiType?: NonNullable<DocumentTypeDecoration<TResult, TVariables>['__apiType']>;
  private value: string;
  public __meta__?: Record<string, any> | undefined;

  constructor(value: string, __meta__?: Record<string, any> | undefined) {
    super(value);
    this.value = value;
    this.__meta__ = __meta__;
  }

  override toString(): string & DocumentTypeDecoration<TResult, TVariables> {
    return this.value;
  }
}

export const ListWatchesDocument = new TypedDocumentString(`
    query ListWatches($sort: [WatchSortInput], $filter: WatchFilterInput, $projectId: ID!) {
  listWatches(sort: $sort, filter: $filter, projectId: $projectId) {
    id
    name
    path
    layer
    kind
    cron
    at
    expiresAt
    maxRuns
    timeoutMs
    budgetPerHour
    nextDueAt
    state
    runningSince
    lastRunAt
    lastDurationMs
    lastError
    lastOutput
    lastSentTo
    runs
    sends
    sendsThisHour
    hourStartedAt
    enabled
    disabledReason
    loadError
    webhookToken
    insertedAt
    updatedAt
    projectId
  }
}
    `) as unknown as TypedDocumentString<ListWatchesQuery, ListWatchesQueryVariables>;
export const ListAllWatchesDocument = new TypedDocumentString(`
    query ListAllWatches {
  listAllWatches {
    watches
  }
}
    `) as unknown as TypedDocumentString<ListAllWatchesQuery, ListAllWatchesQueryVariables>;
export const ListCredentialsDocument = new TypedDocumentString(`
    query ListCredentials($sort: [CredentialSortInput], $filter: CredentialFilterInput) {
  listCredentials(sort: $sort, filter: $filter) {
    id
    name
    label
    kind
    header
    scheme
    allowedHosts
    clientId
    authorizeUrl
    tokenUrl
    registrationUrl
    scopes
    pkce
    extraParams
    fixedClient
    redirectUri
    authorizeParams
    deviceFlow
    expiresAt
    refreshedAt
    lastError
    lastErrorAt
    insertedAt
    updatedAt
    hasSecret
    hasAccessToken
    hasRefreshToken
    hasClientSecret
    status
  }
}
    `) as unknown as TypedDocumentString<ListCredentialsQuery, ListCredentialsQueryVariables>;
export const CredentialRedirectUriDocument = new TypedDocumentString(`
    query CredentialRedirectUri($origin: String) {
  credentialRedirectUri(origin: $origin) {
    uri
  }
}
    `) as unknown as TypedDocumentString<CredentialRedirectUriQuery, CredentialRedirectUriQueryVariables>;
export const ListChromeBrowsersDocument = new TypedDocumentString(`
    query ListChromeBrowsers {
  listChromeBrowsers {
    browsers {
      tabs {
        title
        threadId
        tabs
      }
      status
      name
      maxTabs
      lastSeenAt
      id
      device
      connected
      approvedAt
      aliases
    }
  }
}
    `) as unknown as TypedDocumentString<ListChromeBrowsersQuery, ListChromeBrowsersQueryVariables>;
export const ChromeAliasesDocument = new TypedDocumentString(`
    query ChromeAliases {
  chromeAliases {
    default
    aliases {
      name
      browsers
    }
  }
}
    `) as unknown as TypedDocumentString<ChromeAliasesQuery, ChromeAliasesQueryVariables>;
export const ChromeExtensionDocument = new TypedDocumentString(`
    query ChromeExtension {
  chromeExtension {
    version
    url
    minimumChrome
    built
  }
}
    `) as unknown as TypedDocumentString<ChromeExtensionQuery, ChromeExtensionQueryVariables>;
export const ListDirectoryDocument = new TypedDocumentString(`
    query ListDirectory($path: String, $showHidden: Boolean) {
  listDirectory(path: $path, showHidden: $showHidden) {
    roots
    path
    parent
    git
    entries
  }
}
    `) as unknown as TypedDocumentString<ListDirectoryQuery, ListDirectoryQueryVariables>;
export const KnowledgeDocsDocument = new TypedDocumentString(`
    query KnowledgeDocs {
  knowledgeDocs {
    writable
    title
    tags
    summary
    root
    path
    always
  }
}
    `) as unknown as TypedDocumentString<KnowledgeDocsQuery, KnowledgeDocsQueryVariables>;
export const KnowledgeReadDocument = new TypedDocumentString(`
    query KnowledgeRead($path: String!) {
  knowledgeRead(path: $path) {
    text
  }
}
    `) as unknown as TypedDocumentString<KnowledgeReadQuery, KnowledgeReadQueryVariables>;
export const AgentSettingsDocument = new TypedDocumentString(`
    query AgentSettings {
  agentSettings {
    modelRetries
    memoryFloorPercent
    maxDepth
    maxChildren
    idleMinutes
    commandShell
    commandOomPriority
    childModel
    childEffort
  }
}
    `) as unknown as TypedDocumentString<AgentSettingsQuery, AgentSettingsQueryVariables>;
export const PublicUrlDocument = new TypedDocumentString(`
    query PublicUrl {
  publicUrl {
    url
    setting
  }
}
    `) as unknown as TypedDocumentString<PublicUrlQuery, PublicUrlQueryVariables>;
export const DependenciesDocument = new TypedDocumentString(`
    query Dependencies {
  dependencies {
    tools
    os
    missing
    installCommand
    checkedAt
  }
}
    `) as unknown as TypedDocumentString<DependenciesQuery, DependenciesQueryVariables>;
export const FileRulesDocument = new TypedDocumentString(`
    query FileRules {
  fileRules {
    watch
    ignore
    builtinWatch
    builtinIgnore
  }
}
    `) as unknown as TypedDocumentString<FileRulesQuery, FileRulesQueryVariables>;
export const SentryStatusDocument = new TypedDocumentString(`
    query SentryStatus {
  sentryStatus {
    release
    environment
    enabled
    dsn
  }
}
    `) as unknown as TypedDocumentString<SentryStatusQuery, SentryStatusQueryVariables>;
export const UpgradeStatusDocument = new TypedDocumentString(`
    query UpgradeStatus {
  upgradeStatus {
    target
    stage
    progress
    notesUrl
    message
    latest
    installed
    hasGithubToken
    error
    current
    container
    checkedAt
    available
  }
}
    `) as unknown as TypedDocumentString<UpgradeStatusQuery, UpgradeStatusQueryVariables>;
export const GatewayRequestsDocument = new TypedDocumentString(`
    query GatewayRequests($limit: Int) {
  gatewayRequests(limit: $limit) {
    requests
    keep
  }
}
    `) as unknown as TypedDocumentString<GatewayRequestsQuery, GatewayRequestsQueryVariables>;
export const RecentFaultsDocument = new TypedDocumentString(`
    query RecentFaults {
  recentFaults {
    recent
    faults
  }
}
    `) as unknown as TypedDocumentString<RecentFaultsQuery, RecentFaultsQueryVariables>;
export const RunningCommandsDocument = new TypedDocumentString(`
    query RunningCommands {
  runningCommands {
    commands
  }
}
    `) as unknown as TypedDocumentString<RunningCommandsQuery, RunningCommandsQueryVariables>;
export const BrowserSettingsDocument = new TypedDocumentString(`
    query BrowserSettings {
  browserSettings {
    available
    allowPrivateNetwork
  }
}
    `) as unknown as TypedDocumentString<BrowserSettingsQuery, BrowserSettingsQueryVariables>;
export const BrowserStatusDocument = new TypedDocumentString(`
    query BrowserStatus {
  browserStatus {
    version
    upgradable
    total
    target
    stage
    source
    received
    path
    latest
    installedVersion
    error
  }
}
    `) as unknown as TypedDocumentString<BrowserStatusQuery, BrowserStatusQueryVariables>;
export const TlsStatusDocument = new TypedDocumentString(`
    query TlsStatus {
  tlsStatus {
    url
    total
    toolVersion
    toolInstalled
    startedAt
    stage
    serving
    resolvers
    redirect
    received
    provider
    propagationWait
    propagationCheck
    port
    httpPort
    finishedAt
    error
    envSet
    enabled
    email
    domains
    directory
    certificate {
      serial
      notBefore
      notAfter
      issuedAt
      domains
    }
    addresses
  }
}
    `) as unknown as TypedDocumentString<TlsStatusQuery, TlsStatusQueryVariables>;
export const TlsProvidersDocument = new TypedDocumentString(`
    query TlsProviders {
  tlsProviders {
    providers {
      url
      name
      credentials {
        name
        description
      }
      code
      aliases
      additional {
        name
        description
      }
    }
  }
}
    `) as unknown as TypedDocumentString<TlsProvidersQuery, TlsProvidersQueryVariables>;
export const TlsResolutionDocument = new TypedDocumentString(`
    query TlsResolution($domains: [String!]!) {
  tlsResolution(domains: $domains) {
    resolution {
      local
      here
      fakeIp
      domain
      addresses
    }
    fakeIp
    checkResolvers
    addresses
  }
}
    `) as unknown as TypedDocumentString<TlsResolutionQuery, TlsResolutionQueryVariables>;
export const ListProvidersDocument = new TypedDocumentString(`
    query ListProviders($sort: [ProviderSortInput], $filter: ProviderFilterInput) {
  listProviders(sort: $sort, filter: $filter) {
    id
    name
    slug
    baseUrl
    credentialId
    kind
    supportsHostedWebSearch
    promptCacheKey
    requestTimeoutMs
    streamIdleTimeoutMs
    maxConcurrentRequests
    lastCheckedAt
    lastError
    lastErrorAt
    insertedAt
    updatedAt
    hasApiKey
  }
}
    `) as unknown as TypedDocumentString<ListProvidersQuery, ListProvidersQueryVariables>;
export const ListModelsDocument = new TypedDocumentString(`
    query ListModels($sort: [ModelSortInput], $filter: ModelFilterInput) {
  listModels(sort: $sort, filter: $filter) {
    id
    name
    slug
    upstreamId
    contextWindow
    default
    reasoningLevels
    reasoningEffort
    reasoningSummary
    verbosity
    hostedWebSearch
    imageGeneration
    maxOutputTokens
    insertedAt
    updatedAt
    providerId
    provider {
      id
      name
      slug
      baseUrl
      credentialId
      kind
      supportsHostedWebSearch
      promptCacheKey
      requestTimeoutMs
      streamIdleTimeoutMs
      maxConcurrentRequests
      lastCheckedAt
      lastError
      lastErrorAt
      insertedAt
      updatedAt
      hasApiKey
    }
  }
}
    `) as unknown as TypedDocumentString<ListModelsQuery, ListModelsQueryVariables>;
export const DefaultModelSettingDocument = new TypedDocumentString(`
    query DefaultModelSetting {
  defaultModelSetting {
    slug
    name
    kind
  }
}
    `) as unknown as TypedDocumentString<DefaultModelSettingQuery, DefaultModelSettingQueryVariables>;
export const ModelAliasesDocument = new TypedDocumentString(`
    query ModelAliases {
  modelAliases {
    name
    models
    label
    efforts
    builtin
  }
}
    `) as unknown as TypedDocumentString<ModelAliasesQuery, ModelAliasesQueryVariables>;
export const ListSearchProvidersDocument = new TypedDocumentString(`
    query ListSearchProviders($sort: [SearchProviderSortInput], $filter: SearchProviderFilterInput) {
  listSearchProviders(sort: $sort, filter: $filter) {
    id
    name
    slug
    kind
    baseUrl
    default
    hasApiKey
  }
}
    `) as unknown as TypedDocumentString<ListSearchProvidersQuery, ListSearchProvidersQueryVariables>;
export const ListPresetsDocument = new TypedDocumentString(`
    query ListPresets {
  listPresets {
    supportsHostedWebSearch
    slug
    providerId
    name
    models
    kind
    keyUrl
    keyEnv
    installed
    docsUrl
    credential
    baseUrl
  }
}
    `) as unknown as TypedDocumentString<ListPresetsQuery, ListPresetsQueryVariables>;
export const ListProjectsDocument = new TypedDocumentString(`
    query ListProjects($sort: [ProjectSortInput], $filter: ProjectFilterInput) {
  listProjects(sort: $sort, filter: $filter) {
    id
    name
    slug
    description
    rootPath
    webSearch
    trustLocalAgent
    agentSettings
    fileRules
    archivedAt
    insertedAt
    updatedAt
    modelId
  }
}
    `) as unknown as TypedDocumentString<ListProjectsQuery, ListProjectsQueryVariables>;
export const ListAllProjectsDocument = new TypedDocumentString(`
    query ListAllProjects($sort: [ProjectSortInput], $filter: ProjectFilterInput) {
  listAllProjects(sort: $sort, filter: $filter) {
    id
    name
    slug
    description
    rootPath
    webSearch
    trustLocalAgent
    agentSettings
    fileRules
    archivedAt
    insertedAt
    updatedAt
    modelId
  }
}
    `) as unknown as TypedDocumentString<ListAllProjectsQuery, ListAllProjectsQueryVariables>;
export const GetProjectDocument = new TypedDocumentString(`
    query GetProject($filter: ProjectFilterInput, $slug: String!) {
  getProject(filter: $filter, slug: $slug) {
    id
    name
    slug
    description
    rootPath
    webSearch
    trustLocalAgent
    agentSettings
    fileRules
    archivedAt
    insertedAt
    updatedAt
    modelId
  }
}
    `) as unknown as TypedDocumentString<GetProjectQuery, GetProjectQueryVariables>;
export const GitInfoDocument = new TypedDocumentString(`
    query GitInfo($id: ID!) {
  gitInfo(id: $id) {
    repository
    lfs
    head
    clean
    changes
  }
}
    `) as unknown as TypedDocumentString<GitInfoQuery, GitInfoQueryVariables>;
export const SearchFilesDocument = new TypedDocumentString(`
    query SearchFiles($id: ID!, $query: String!) {
  searchFiles(id: $id, query: $query) {
    score
    root
    path
    matchType
    indices
    fileName
  }
}
    `) as unknown as TypedDocumentString<SearchFilesQuery, SearchFilesQueryVariables>;
export const AgentDefinitionDocument = new TypedDocumentString(`
    query AgentDefinition($id: ID!) {
  agentDefinition(id: $id) {
    trusted
    settings {
      modelRetries
      memoryFloorPercent
      maxDepth
      maxChildren
      idleMinutes
      commandOomPriority
      childModel
      childEffort
    }
    present
    plugs
    overrides {
      modelRetries
      memoryFloorPercent
      maxDepth
      maxChildren
      idleMinutes
      commandOomPriority
      childModel
      childEffort
    }
    model
    localFiles
    files
    errors
    effort
    dir
    browser {
      state
      maxTabs
      browser
      alias
    }
    agents
  }
}
    `) as unknown as TypedDocumentString<AgentDefinitionQuery, AgentDefinitionQueryVariables>;
export const ListThreadsDocument = new TypedDocumentString(`
    query ListThreads($sort: [ThreadSortInput], $filter: ThreadFilterInput, $projectId: ID!) {
  listThreads(sort: $sort, filter: $filter, projectId: $projectId) {
    id
    kernelThreadId
    title
    preview
    handle
    onDuty
    cwd
    modelSlug
    reasoningEffort
    webSearch
    agentPath
    status
    lastActivityAt
    insertedAt
    updatedAt
    projectId
    parentThreadId
  }
}
    `) as unknown as TypedDocumentString<ListThreadsQuery, ListThreadsQueryVariables>;
export const GetThreadDocument = new TypedDocumentString(`
    query GetThread($filter: ThreadFilterInput, $id: ID!) {
  getThread(filter: $filter, id: $id) {
    id
    kernelThreadId
    title
    preview
    handle
    onDuty
    cwd
    modelSlug
    reasoningEffort
    webSearch
    agentPath
    status
    lastActivityAt
    insertedAt
    updatedAt
    projectId
    parentThreadId
  }
}
    `) as unknown as TypedDocumentString<GetThreadQuery, GetThreadQueryVariables>;
export const ListSubagentsDocument = new TypedDocumentString(`
    query ListSubagents($sort: [ThreadSortInput], $filter: ThreadFilterInput, $parentThreadId: ID!) {
  listSubagents(sort: $sort, filter: $filter, parentThreadId: $parentThreadId) {
    id
    kernelThreadId
    title
    preview
    handle
    onDuty
    cwd
    modelSlug
    reasoningEffort
    webSearch
    agentPath
    status
    lastActivityAt
    insertedAt
    updatedAt
    projectId
    parentThreadId
  }
}
    `) as unknown as TypedDocumentString<ListSubagentsQuery, ListSubagentsQueryVariables>;
export const ListRunningThreadsDocument = new TypedDocumentString(`
    query ListRunningThreads {
  listRunningThreads {
    threads
    finished
  }
}
    `) as unknown as TypedDocumentString<ListRunningThreadsQuery, ListRunningThreadsQueryVariables>;
export const ListRecentThreadsDocument = new TypedDocumentString(`
    query ListRecentThreads($limit: Int) {
  listRecentThreads(limit: $limit) {
    threads
  }
}
    `) as unknown as TypedDocumentString<ListRecentThreadsQuery, ListRecentThreadsQueryVariables>;
export const ProjectJobsDocument = new TypedDocumentString(`
    query ProjectJobs($projectId: ID!) {
  projectJobs(projectId: $projectId) {
    jobs
  }
}
    `) as unknown as TypedDocumentString<ProjectJobsQuery, ProjectJobsQueryVariables>;
export const DirectoryDocument = new TypedDocumentString(`
    query Directory($projectId: ID!, $scope: String) {
  directory(projectId: $projectId, scope: $scope) {
    sessions
  }
}
    `) as unknown as TypedDocumentString<DirectoryQuery, DirectoryQueryVariables>;
export const ListFilesDocument = new TypedDocumentString(`
    query ListFiles($projectId: ID!, $path: String!) {
  listFiles(projectId: $projectId, path: $path) {
    size
    path
    name
    kind
  }
}
    `) as unknown as TypedDocumentString<ListFilesQuery, ListFilesQueryVariables>;
export const ReadFileDocument = new TypedDocumentString(`
    query ReadFile($projectId: ID!, $path: String!) {
  readFile(projectId: $projectId, path: $path) {
    truncated
    size
    path
    content
    binary
  }
}
    `) as unknown as TypedDocumentString<ReadFileQuery, ReadFileQueryVariables>;
export const IgnoredPathsDocument = new TypedDocumentString(`
    query IgnoredPaths($projectId: ID!) {
  ignoredPaths(projectId: $projectId)
}
    `) as unknown as TypedDocumentString<IgnoredPathsQuery, IgnoredPathsQueryVariables>;
export const GitChangesDocument = new TypedDocumentString(`
    query GitChanges($projectId: ID!) {
  gitChanges(projectId: $projectId) {
    repository
    remotes
    merging
    lfs
    ignored
    head
    changes
    branch
    behind
    ahead
  }
}
    `) as unknown as TypedDocumentString<GitChangesQuery, GitChangesQueryVariables>;
export const GitFileDiffDocument = new TypedDocumentString(`
    query GitFileDiff($projectId: ID!, $path: String!) {
  gitFileDiff(projectId: $projectId, path: $path) {
    diff
    binary
  }
}
    `) as unknown as TypedDocumentString<GitFileDiffQuery, GitFileDiffQueryVariables>;
export const GitLogDocument = new TypedDocumentString(`
    query GitLog($projectId: ID!, $limit: Int, $skip: Int) {
  gitLog(projectId: $projectId, limit: $limit, skip: $skip) {
    subject
    sha
    email
    author
    at
  }
}
    `) as unknown as TypedDocumentString<GitLogQuery, GitLogQueryVariables>;
export const GitShowDocument = new TypedDocumentString(`
    query GitShow($projectId: ID!, $sha: String!) {
  gitShow(projectId: $projectId, sha: $sha) {
    subject
    sha
    parents
    files
    email
    body
    author
    at
  }
}
    `) as unknown as TypedDocumentString<GitShowQuery, GitShowQueryVariables>;
export const GitCommitFileDiffDocument = new TypedDocumentString(`
    query GitCommitFileDiff($projectId: ID!, $sha: String!, $path: String!) {
  gitCommitFileDiff(projectId: $projectId, sha: $sha, path: $path) {
    diff
    binary
  }
}
    `) as unknown as TypedDocumentString<GitCommitFileDiffQuery, GitCommitFileDiffQueryVariables>;
export const GitFileVersionsDocument = new TypedDocumentString(`
    query GitFileVersions($projectId: ID!, $sha: String, $path: String!) {
  gitFileVersions(projectId: $projectId, sha: $sha, path: $path) {
    binary
    before
    after
  }
}
    `) as unknown as TypedDocumentString<GitFileVersionsQuery, GitFileVersionsQueryVariables>;
export const GitBranchesDocument = new TypedDocumentString(`
    query GitBranches($projectId: ID!) {
  gitBranches(projectId: $projectId) {
    stashes
    current
    branches
  }
}
    `) as unknown as TypedDocumentString<GitBranchesQuery, GitBranchesQueryVariables>;
export const ListTurnsDocument = new TypedDocumentString(`
    query ListTurns($sort: [TurnSortInput], $filter: TurnFilterInput, $threadId: ID!, $includeReverted: Boolean) {
  listTurns(
    sort: $sort
    filter: $filter
    threadId: $threadId
    includeReverted: $includeReverted
  ) {
    id
    kernelTurnId
    userText
    modelSlug
    reasoningEffort
    status
    startedAt
    completedAt
    error
    usage
    insertedAt
    updatedAt
    threadId
  }
}
    `) as unknown as TypedDocumentString<ListTurnsQuery, ListTurnsQueryVariables>;
export const SwitchWatchDocument = new TypedDocumentString(`
    mutation SwitchWatch($input: SwitchWatchInput!) {
  switchWatch(input: $input) {
    id
    name
    path
    layer
    kind
    cron
    at
    expiresAt
    maxRuns
    timeoutMs
    budgetPerHour
    nextDueAt
    state
    runningSince
    lastRunAt
    lastDurationMs
    lastError
    lastOutput
    lastSentTo
    runs
    sends
    sendsThisHour
    hourStartedAt
    enabled
    disabledReason
    loadError
    webhookToken
    insertedAt
    updatedAt
    projectId
  }
}
    `) as unknown as TypedDocumentString<SwitchWatchMutation, SwitchWatchMutationVariables>;
export const DryRunWatchDocument = new TypedDocumentString(`
    mutation DryRunWatch($input: DryRunWatchInput!) {
  dryRunWatch(input: $input) {
    sends
    result
    ok
    log
  }
}
    `) as unknown as TypedDocumentString<DryRunWatchMutation, DryRunWatchMutationVariables>;
export const DeleteWatchDocument = new TypedDocumentString(`
    mutation DeleteWatch($input: DeleteWatchInput!) {
  deleteWatch(input: $input)
}
    `) as unknown as TypedDocumentString<DeleteWatchMutation, DeleteWatchMutationVariables>;
export const CreateCredentialApiKeyDocument = new TypedDocumentString(`
    mutation CreateCredentialApiKey($input: CreateCredentialApiKeyInput!) {
  createCredentialApiKey(input: $input) {
    result {
      id
      name
      label
      kind
      header
      scheme
      allowedHosts
      clientId
      authorizeUrl
      tokenUrl
      registrationUrl
      scopes
      pkce
      extraParams
      fixedClient
      redirectUri
      authorizeParams
      deviceFlow
      expiresAt
      refreshedAt
      lastError
      lastErrorAt
      insertedAt
      updatedAt
      hasSecret
      hasAccessToken
      hasRefreshToken
      hasClientSecret
      status
    }
  }
}
    `) as unknown as TypedDocumentString<CreateCredentialApiKeyMutation, CreateCredentialApiKeyMutationVariables>;
export const CreateCredentialOauth2Document = new TypedDocumentString(`
    mutation CreateCredentialOauth2($input: CreateCredentialOauth2Input!) {
  createCredentialOauth2(input: $input) {
    result {
      id
      name
      label
      kind
      header
      scheme
      allowedHosts
      clientId
      authorizeUrl
      tokenUrl
      registrationUrl
      scopes
      pkce
      extraParams
      fixedClient
      redirectUri
      authorizeParams
      deviceFlow
      expiresAt
      refreshedAt
      lastError
      lastErrorAt
      insertedAt
      updatedAt
      hasSecret
      hasAccessToken
      hasRefreshToken
      hasClientSecret
      status
    }
  }
}
    `) as unknown as TypedDocumentString<CreateCredentialOauth2Mutation, CreateCredentialOauth2MutationVariables>;
export const UpdateCredentialDocument = new TypedDocumentString(`
    mutation UpdateCredential($id: ID!, $input: UpdateCredentialInput) {
  updateCredential(id: $id, input: $input) {
    result {
      id
      name
      label
      kind
      header
      scheme
      allowedHosts
      clientId
      authorizeUrl
      tokenUrl
      registrationUrl
      scopes
      pkce
      extraParams
      fixedClient
      redirectUri
      authorizeParams
      deviceFlow
      expiresAt
      refreshedAt
      lastError
      lastErrorAt
      insertedAt
      updatedAt
      hasSecret
      hasAccessToken
      hasRefreshToken
      hasClientSecret
      status
    }
  }
}
    `) as unknown as TypedDocumentString<UpdateCredentialMutation, UpdateCredentialMutationVariables>;
export const DeleteCredentialDocument = new TypedDocumentString(`
    mutation DeleteCredential($id: ID!) {
  deleteCredential(id: $id) {
    result {
      id
      name
      label
      kind
      header
      scheme
      allowedHosts
      clientId
      authorizeUrl
      tokenUrl
      registrationUrl
      scopes
      pkce
      extraParams
      fixedClient
      redirectUri
      authorizeParams
      deviceFlow
      expiresAt
      refreshedAt
      lastError
      lastErrorAt
      insertedAt
      updatedAt
      hasSecret
      hasAccessToken
      hasRefreshToken
      hasClientSecret
      status
    }
  }
}
    `) as unknown as TypedDocumentString<DeleteCredentialMutation, DeleteCredentialMutationVariables>;
export const CredentialLoginUrlDocument = new TypedDocumentString(`
    mutation CredentialLoginUrl($input: CredentialLoginUrlInput!) {
  credentialLoginUrl(input: $input) {
    url
    redirectUri
    loopback
  }
}
    `) as unknown as TypedDocumentString<CredentialLoginUrlMutation, CredentialLoginUrlMutationVariables>;
export const RefreshCredentialDocument = new TypedDocumentString(`
    mutation RefreshCredential($input: RefreshCredentialInput!) {
  refreshCredential(input: $input) {
    id
    name
    label
    kind
    header
    scheme
    allowedHosts
    clientId
    authorizeUrl
    tokenUrl
    registrationUrl
    scopes
    pkce
    extraParams
    fixedClient
    redirectUri
    authorizeParams
    deviceFlow
    expiresAt
    refreshedAt
    lastError
    lastErrorAt
    insertedAt
    updatedAt
    hasSecret
    hasAccessToken
    hasRefreshToken
    hasClientSecret
    status
  }
}
    `) as unknown as TypedDocumentString<RefreshCredentialMutation, RefreshCredentialMutationVariables>;
export const CredentialCompleteUrlDocument = new TypedDocumentString(`
    mutation CredentialCompleteUrl($input: CredentialCompleteUrlInput!) {
  credentialCompleteUrl(input: $input) {
    id
    name
    label
    kind
    header
    scheme
    allowedHosts
    clientId
    authorizeUrl
    tokenUrl
    registrationUrl
    scopes
    pkce
    extraParams
    fixedClient
    redirectUri
    authorizeParams
    deviceFlow
    expiresAt
    refreshedAt
    lastError
    lastErrorAt
    insertedAt
    updatedAt
    hasSecret
    hasAccessToken
    hasRefreshToken
    hasClientSecret
    status
  }
}
    `) as unknown as TypedDocumentString<CredentialCompleteUrlMutation, CredentialCompleteUrlMutationVariables>;
export const CredentialDeviceBeginDocument = new TypedDocumentString(`
    mutation CredentialDeviceBegin($input: CredentialDeviceBeginInput!) {
  credentialDeviceBegin(input: $input) {
    verificationUrl
    userCode
    state
    interval
  }
}
    `) as unknown as TypedDocumentString<CredentialDeviceBeginMutation, CredentialDeviceBeginMutationVariables>;
export const CredentialDevicePollDocument = new TypedDocumentString(`
    mutation CredentialDevicePoll($input: CredentialDevicePollInput!) {
  credentialDevicePoll(input: $input) {
    status
    message
  }
}
    `) as unknown as TypedDocumentString<CredentialDevicePollMutation, CredentialDevicePollMutationVariables>;
export const ApproveChromeBrowserDocument = new TypedDocumentString(`
    mutation ApproveChromeBrowser($input: ApproveChromeBrowserInput!) {
  approveChromeBrowser(input: $input) {
    ok
  }
}
    `) as unknown as TypedDocumentString<ApproveChromeBrowserMutation, ApproveChromeBrowserMutationVariables>;
export const RejectChromeBrowserDocument = new TypedDocumentString(`
    mutation RejectChromeBrowser($input: RejectChromeBrowserInput!) {
  rejectChromeBrowser(input: $input) {
    ok
  }
}
    `) as unknown as TypedDocumentString<RejectChromeBrowserMutation, RejectChromeBrowserMutationVariables>;
export const RevokeChromeBrowserDocument = new TypedDocumentString(`
    mutation RevokeChromeBrowser($input: RevokeChromeBrowserInput!) {
  revokeChromeBrowser(input: $input) {
    ok
  }
}
    `) as unknown as TypedDocumentString<RevokeChromeBrowserMutation, RevokeChromeBrowserMutationVariables>;
export const RenameChromeBrowserDocument = new TypedDocumentString(`
    mutation RenameChromeBrowser($input: RenameChromeBrowserInput!) {
  renameChromeBrowser(input: $input) {
    ok
  }
}
    `) as unknown as TypedDocumentString<RenameChromeBrowserMutation, RenameChromeBrowserMutationVariables>;
export const SetChromeBrowserMaxTabsDocument = new TypedDocumentString(`
    mutation SetChromeBrowserMaxTabs($input: SetChromeBrowserMaxTabsInput!) {
  setChromeBrowserMaxTabs(input: $input) {
    ok
  }
}
    `) as unknown as TypedDocumentString<SetChromeBrowserMaxTabsMutation, SetChromeBrowserMaxTabsMutationVariables>;
export const SetChromeAliasDocument = new TypedDocumentString(`
    mutation SetChromeAlias($input: SetChromeAliasInput!) {
  setChromeAlias(input: $input) {
    default
    aliases {
      name
      browsers
    }
  }
}
    `) as unknown as TypedDocumentString<SetChromeAliasMutation, SetChromeAliasMutationVariables>;
export const DeleteChromeAliasDocument = new TypedDocumentString(`
    mutation DeleteChromeAlias($input: DeleteChromeAliasInput!) {
  deleteChromeAlias(input: $input) {
    default
    aliases {
      name
      browsers
    }
  }
}
    `) as unknown as TypedDocumentString<DeleteChromeAliasMutation, DeleteChromeAliasMutationVariables>;
export const SetChromeDefaultAliasDocument = new TypedDocumentString(`
    mutation SetChromeDefaultAlias($input: SetChromeDefaultAliasInput) {
  setChromeDefaultAlias(input: $input) {
    default
    aliases {
      name
      browsers
    }
  }
}
    `) as unknown as TypedDocumentString<SetChromeDefaultAliasMutation, SetChromeDefaultAliasMutationVariables>;
export const CreateDirectoryDocument = new TypedDocumentString(`
    mutation CreateDirectory($input: CreateDirectoryInput!) {
  createDirectory(input: $input) {
    path
    name
    git
  }
}
    `) as unknown as TypedDocumentString<CreateDirectoryMutation, CreateDirectoryMutationVariables>;
export const KnowledgeWriteDocument = new TypedDocumentString(`
    mutation KnowledgeWrite($input: KnowledgeWriteInput!) {
  knowledgeWrite(input: $input)
}
    `) as unknown as TypedDocumentString<KnowledgeWriteMutation, KnowledgeWriteMutationVariables>;
export const KnowledgeDeleteDocument = new TypedDocumentString(`
    mutation KnowledgeDelete($input: KnowledgeDeleteInput!) {
  knowledgeDelete(input: $input)
}
    `) as unknown as TypedDocumentString<KnowledgeDeleteMutation, KnowledgeDeleteMutationVariables>;
export const SetAgentSettingsDocument = new TypedDocumentString(`
    mutation SetAgentSettings($input: SetAgentSettingsInput) {
  setAgentSettings(input: $input) {
    modelRetries
    memoryFloorPercent
    maxDepth
    maxChildren
    idleMinutes
    commandShell
    commandOomPriority
    childModel
    childEffort
  }
}
    `) as unknown as TypedDocumentString<SetAgentSettingsMutation, SetAgentSettingsMutationVariables>;
export const CheckDependenciesDocument = new TypedDocumentString(`
    mutation CheckDependencies {
  checkDependencies {
    tools
    os
    missing
    installCommand
    checkedAt
  }
}
    `) as unknown as TypedDocumentString<CheckDependenciesMutation, CheckDependenciesMutationVariables>;
export const SetPublicUrlDocument = new TypedDocumentString(`
    mutation SetPublicUrl($input: SetPublicUrlInput!) {
  setPublicUrl(input: $input) {
    url
    setting
  }
}
    `) as unknown as TypedDocumentString<SetPublicUrlMutation, SetPublicUrlMutationVariables>;
export const SetFileRulesDocument = new TypedDocumentString(`
    mutation SetFileRules($input: SetFileRulesInput) {
  setFileRules(input: $input) {
    watch
    ignore
    builtinWatch
    builtinIgnore
  }
}
    `) as unknown as TypedDocumentString<SetFileRulesMutation, SetFileRulesMutationVariables>;
export const SetSentryDsnDocument = new TypedDocumentString(`
    mutation SetSentryDsn($input: SetSentryDsnInput!) {
  setSentryDsn(input: $input) {
    release
    environment
    enabled
    dsn
  }
}
    `) as unknown as TypedDocumentString<SetSentryDsnMutation, SetSentryDsnMutationVariables>;
export const SentryTestDocument = new TypedDocumentString(`
    mutation SentryTest {
  sentryTest {
    ok
    message
  }
}
    `) as unknown as TypedDocumentString<SentryTestMutation, SentryTestMutationVariables>;
export const UpgradeCheckDocument = new TypedDocumentString(`
    mutation UpgradeCheck {
  upgradeCheck {
    target
    stage
    progress
    notesUrl
    message
    latest
    installed
    hasGithubToken
    error
    current
    container
    checkedAt
    available
  }
}
    `) as unknown as TypedDocumentString<UpgradeCheckMutation, UpgradeCheckMutationVariables>;
export const UpgradeApplyDocument = new TypedDocumentString(`
    mutation UpgradeApply {
  upgradeApply {
    target
    stage
    progress
    notesUrl
    message
    latest
    installed
    hasGithubToken
    error
    current
    container
    checkedAt
    available
  }
}
    `) as unknown as TypedDocumentString<UpgradeApplyMutation, UpgradeApplyMutationVariables>;
export const SetGithubTokenDocument = new TypedDocumentString(`
    mutation SetGithubToken($input: SetGithubTokenInput) {
  setGithubToken(input: $input) {
    target
    stage
    progress
    notesUrl
    message
    latest
    installed
    hasGithubToken
    error
    current
    container
    checkedAt
    available
  }
}
    `) as unknown as TypedDocumentString<SetGithubTokenMutation, SetGithubTokenMutationVariables>;
export const KillCommandDocument = new TypedDocumentString(`
    mutation KillCommand($input: KillCommandInput!) {
  killCommand(input: $input) {
    ok
  }
}
    `) as unknown as TypedDocumentString<KillCommandMutation, KillCommandMutationVariables>;
export const BrowserInstallDocument = new TypedDocumentString(`
    mutation BrowserInstall {
  browserInstall {
    version
    upgradable
    total
    target
    stage
    source
    received
    path
    latest
    installedVersion
    error
  }
}
    `) as unknown as TypedDocumentString<BrowserInstallMutation, BrowserInstallMutationVariables>;
export const SetBrowserPrivateNetworkDocument = new TypedDocumentString(`
    mutation SetBrowserPrivateNetwork($input: SetBrowserPrivateNetworkInput!) {
  setBrowserPrivateNetwork(input: $input) {
    available
    allowPrivateNetwork
  }
}
    `) as unknown as TypedDocumentString<SetBrowserPrivateNetworkMutation, SetBrowserPrivateNetworkMutationVariables>;
export const SetTlsDocument = new TypedDocumentString(`
    mutation SetTls($input: SetTlsInput) {
  setTls(input: $input) {
    url
    total
    toolVersion
    toolInstalled
    startedAt
    stage
    serving
    resolvers
    redirect
    received
    provider
    propagationWait
    propagationCheck
    port
    httpPort
    finishedAt
    error
    envSet
    enabled
    email
    domains
    directory
    certificate {
      serial
      notBefore
      notAfter
      issuedAt
      domains
    }
    addresses
  }
}
    `) as unknown as TypedDocumentString<SetTlsMutation, SetTlsMutationVariables>;
export const TlsIssueDocument = new TypedDocumentString(`
    mutation TlsIssue {
  tlsIssue {
    url
    total
    toolVersion
    toolInstalled
    startedAt
    stage
    serving
    resolvers
    redirect
    received
    provider
    propagationWait
    propagationCheck
    port
    httpPort
    finishedAt
    error
    envSet
    enabled
    email
    domains
    directory
    certificate {
      serial
      notBefore
      notAfter
      issuedAt
      domains
    }
    addresses
  }
}
    `) as unknown as TypedDocumentString<TlsIssueMutation, TlsIssueMutationVariables>;
export const TlsDisableDocument = new TypedDocumentString(`
    mutation TlsDisable {
  tlsDisable {
    url
    total
    toolVersion
    toolInstalled
    startedAt
    stage
    serving
    resolvers
    redirect
    received
    provider
    propagationWait
    propagationCheck
    port
    httpPort
    finishedAt
    error
    envSet
    enabled
    email
    domains
    directory
    certificate {
      serial
      notBefore
      notAfter
      issuedAt
      domains
    }
    addresses
  }
}
    `) as unknown as TypedDocumentString<TlsDisableMutation, TlsDisableMutationVariables>;
export const CreateProviderDocument = new TypedDocumentString(`
    mutation CreateProvider($input: CreateProviderInput!) {
  createProvider(input: $input) {
    result {
      id
      name
      slug
      baseUrl
      credentialId
      kind
      supportsHostedWebSearch
      promptCacheKey
      requestTimeoutMs
      streamIdleTimeoutMs
      maxConcurrentRequests
      lastCheckedAt
      lastError
      lastErrorAt
      insertedAt
      updatedAt
      hasApiKey
    }
  }
}
    `) as unknown as TypedDocumentString<CreateProviderMutation, CreateProviderMutationVariables>;
export const UpdateProviderDocument = new TypedDocumentString(`
    mutation UpdateProvider($id: ID!, $input: UpdateProviderInput) {
  updateProvider(id: $id, input: $input) {
    result {
      id
      name
      slug
      baseUrl
      credentialId
      kind
      supportsHostedWebSearch
      promptCacheKey
      requestTimeoutMs
      streamIdleTimeoutMs
      maxConcurrentRequests
      lastCheckedAt
      lastError
      lastErrorAt
      insertedAt
      updatedAt
      hasApiKey
    }
  }
}
    `) as unknown as TypedDocumentString<UpdateProviderMutation, UpdateProviderMutationVariables>;
export const DeleteProviderDocument = new TypedDocumentString(`
    mutation DeleteProvider($id: ID!) {
  deleteProvider(id: $id) {
    result {
      id
      name
      slug
      baseUrl
      credentialId
      kind
      supportsHostedWebSearch
      promptCacheKey
      requestTimeoutMs
      streamIdleTimeoutMs
      maxConcurrentRequests
      lastCheckedAt
      lastError
      lastErrorAt
      insertedAt
      updatedAt
      hasApiKey
    }
  }
}
    `) as unknown as TypedDocumentString<DeleteProviderMutation, DeleteProviderMutationVariables>;
export const DiscoverModelsDocument = new TypedDocumentString(`
    mutation DiscoverModels($input: DiscoverModelsInput!) {
  discoverModels(input: $input) {
    ok
    models
    error
  }
}
    `) as unknown as TypedDocumentString<DiscoverModelsMutation, DiscoverModelsMutationVariables>;
export const CreateModelDocument = new TypedDocumentString(`
    mutation CreateModel($input: CreateModelInput!) {
  createModel(input: $input) {
    result {
      id
      name
      slug
      upstreamId
      contextWindow
      default
      reasoningLevels
      reasoningEffort
      reasoningSummary
      verbosity
      hostedWebSearch
      imageGeneration
      maxOutputTokens
      insertedAt
      updatedAt
      providerId
    }
  }
}
    `) as unknown as TypedDocumentString<CreateModelMutation, CreateModelMutationVariables>;
export const UpdateModelDocument = new TypedDocumentString(`
    mutation UpdateModel($id: ID!, $input: UpdateModelInput) {
  updateModel(id: $id, input: $input) {
    result {
      id
      name
      slug
      upstreamId
      contextWindow
      default
      reasoningLevels
      reasoningEffort
      reasoningSummary
      verbosity
      hostedWebSearch
      imageGeneration
      maxOutputTokens
      insertedAt
      updatedAt
      providerId
    }
  }
}
    `) as unknown as TypedDocumentString<UpdateModelMutation, UpdateModelMutationVariables>;
export const MakeDefaultModelDocument = new TypedDocumentString(`
    mutation MakeDefaultModel($id: ID!) {
  makeDefaultModel(id: $id) {
    result {
      id
      name
      slug
      upstreamId
      contextWindow
      default
      reasoningLevels
      reasoningEffort
      reasoningSummary
      verbosity
      hostedWebSearch
      imageGeneration
      maxOutputTokens
      insertedAt
      updatedAt
      providerId
    }
  }
}
    `) as unknown as TypedDocumentString<MakeDefaultModelMutation, MakeDefaultModelMutationVariables>;
export const SetDefaultModelDocument = new TypedDocumentString(`
    mutation SetDefaultModel($input: SetDefaultModelInput!) {
  setDefaultModel(input: $input) {
    slug
    name
    kind
  }
}
    `) as unknown as TypedDocumentString<SetDefaultModelMutation, SetDefaultModelMutationVariables>;
export const CheckModelDocument = new TypedDocumentString(`
    mutation CheckModel($input: CheckModelInput!) {
  checkModel(input: $input) {
    ok
    latencyMs
    error
  }
}
    `) as unknown as TypedDocumentString<CheckModelMutation, CheckModelMutationVariables>;
export const SetModelAliasDocument = new TypedDocumentString(`
    mutation SetModelAlias($input: SetModelAliasInput!) {
  setModelAlias(input: $input) {
    name
    models
    label
    efforts
    builtin
  }
}
    `) as unknown as TypedDocumentString<SetModelAliasMutation, SetModelAliasMutationVariables>;
export const DeleteModelAliasDocument = new TypedDocumentString(`
    mutation DeleteModelAlias($input: DeleteModelAliasInput!) {
  deleteModelAlias(input: $input)
}
    `) as unknown as TypedDocumentString<DeleteModelAliasMutation, DeleteModelAliasMutationVariables>;
export const DeleteModelDocument = new TypedDocumentString(`
    mutation DeleteModel($id: ID!) {
  deleteModel(id: $id) {
    result {
      id
      name
      slug
      upstreamId
      contextWindow
      default
      reasoningLevels
      reasoningEffort
      reasoningSummary
      verbosity
      hostedWebSearch
      imageGeneration
      maxOutputTokens
      insertedAt
      updatedAt
      providerId
    }
  }
}
    `) as unknown as TypedDocumentString<DeleteModelMutation, DeleteModelMutationVariables>;
export const UpdateSearchProviderDocument = new TypedDocumentString(`
    mutation UpdateSearchProvider($id: ID!, $input: UpdateSearchProviderInput) {
  updateSearchProvider(id: $id, input: $input) {
    result {
      id
      name
      slug
      kind
      baseUrl
      default
      hasApiKey
    }
  }
}
    `) as unknown as TypedDocumentString<UpdateSearchProviderMutation, UpdateSearchProviderMutationVariables>;
export const ApplyPresetDocument = new TypedDocumentString(`
    mutation ApplyPreset($input: ApplyPresetInput!) {
  applyPreset(input: $input) {
    providerId
    modelIds
    credentialId
  }
}
    `) as unknown as TypedDocumentString<ApplyPresetMutation, ApplyPresetMutationVariables>;
export const CreateProjectDocument = new TypedDocumentString(`
    mutation CreateProject($input: CreateProjectInput!) {
  createProject(input: $input) {
    result {
      id
      name
      slug
      description
      rootPath
      webSearch
      trustLocalAgent
      agentSettings
      fileRules
      archivedAt
      insertedAt
      updatedAt
      modelId
    }
  }
}
    `) as unknown as TypedDocumentString<CreateProjectMutation, CreateProjectMutationVariables>;
export const UpdateProjectDocument = new TypedDocumentString(`
    mutation UpdateProject($id: ID!, $input: UpdateProjectInput) {
  updateProject(id: $id, input: $input) {
    result {
      id
      name
      slug
      description
      rootPath
      webSearch
      trustLocalAgent
      agentSettings
      fileRules
      archivedAt
      insertedAt
      updatedAt
      modelId
    }
  }
}
    `) as unknown as TypedDocumentString<UpdateProjectMutation, UpdateProjectMutationVariables>;
export const ArchiveProjectDocument = new TypedDocumentString(`
    mutation ArchiveProject($id: ID!) {
  archiveProject(id: $id) {
    result {
      id
      name
      slug
      description
      rootPath
      webSearch
      trustLocalAgent
      agentSettings
      fileRules
      archivedAt
      insertedAt
      updatedAt
      modelId
    }
  }
}
    `) as unknown as TypedDocumentString<ArchiveProjectMutation, ArchiveProjectMutationVariables>;
export const DeleteProjectDocument = new TypedDocumentString(`
    mutation DeleteProject($id: ID!, $input: DeleteProjectInput) {
  deleteProject(id: $id, input: $input) {
    result {
      id
      name
      slug
      description
      rootPath
      webSearch
      trustLocalAgent
      agentSettings
      fileRules
      archivedAt
      insertedAt
      updatedAt
      modelId
    }
  }
}
    `) as unknown as TypedDocumentString<DeleteProjectMutation, DeleteProjectMutationVariables>;
export const PromoteLocalDocument = new TypedDocumentString(`
    mutation PromoteLocal($input: PromoteLocalInput!) {
  promoteLocal(input: $input) {
    path
  }
}
    `) as unknown as TypedDocumentString<PromoteLocalMutation, PromoteLocalMutationVariables>;
export const InitGitDocument = new TypedDocumentString(`
    mutation InitGit($input: InitGitInput!) {
  initGit(input: $input) {
    repository
    lfs
    head
    clean
    changes
  }
}
    `) as unknown as TypedDocumentString<InitGitMutation, InitGitMutationVariables>;
export const StartThreadDocument = new TypedDocumentString(`
    mutation StartThread($input: StartThreadInput!) {
  startThread(input: $input) {
    id
    kernelThreadId
    title
    preview
    handle
    onDuty
    cwd
    modelSlug
    reasoningEffort
    webSearch
    agentPath
    status
    lastActivityAt
    insertedAt
    updatedAt
    projectId
    parentThreadId
  }
}
    `) as unknown as TypedDocumentString<StartThreadMutation, StartThreadMutationVariables>;
export const SendMessageDocument = new TypedDocumentString(`
    mutation SendMessage($input: SendMessageInput!) {
  sendMessage(input: $input) {
    id
    kernelTurnId
    userText
    modelSlug
    reasoningEffort
    status
    startedAt
    completedAt
    error
    usage
    insertedAt
    updatedAt
    threadId
  }
}
    `) as unknown as TypedDocumentString<SendMessageMutation, SendMessageMutationVariables>;
export const InterruptTurnDocument = new TypedDocumentString(`
    mutation InterruptTurn($input: InterruptTurnInput!) {
  interruptTurn(input: $input)
}
    `) as unknown as TypedDocumentString<InterruptTurnMutation, InterruptTurnMutationVariables>;
export const SteerTurnDocument = new TypedDocumentString(`
    mutation SteerTurn($input: SteerTurnInput!) {
  steerTurn(input: $input) {
    kernelTurnId
  }
}
    `) as unknown as TypedDocumentString<SteerTurnMutation, SteerTurnMutationVariables>;
export const RetractTurnDocument = new TypedDocumentString(`
    mutation RetractTurn($input: RetractTurnInput!) {
  retractTurn(input: $input) {
    text
  }
}
    `) as unknown as TypedDocumentString<RetractTurnMutation, RetractTurnMutationVariables>;
export const ReleaseWaitingDocument = new TypedDocumentString(`
    mutation ReleaseWaiting($input: ReleaseWaitingInput!) {
  releaseWaiting(input: $input)
}
    `) as unknown as TypedDocumentString<ReleaseWaitingMutation, ReleaseWaitingMutationVariables>;
export const CompactThreadDocument = new TypedDocumentString(`
    mutation CompactThread($input: CompactThreadInput!) {
  compactThread(input: $input)
}
    `) as unknown as TypedDocumentString<CompactThreadMutation, CompactThreadMutationVariables>;
export const AnswerRequestDocument = new TypedDocumentString(`
    mutation AnswerRequest($input: AnswerRequestInput!) {
  answerRequest(input: $input)
}
    `) as unknown as TypedDocumentString<AnswerRequestMutation, AnswerRequestMutationVariables>;
export const SetGoalDocument = new TypedDocumentString(`
    mutation SetGoal($input: SetGoalInput!) {
  setGoal(input: $input) {
    tokensUsed
    tokenBudget
    timeUsedSeconds
    status
    objective
  }
}
    `) as unknown as TypedDocumentString<SetGoalMutation, SetGoalMutationVariables>;
export const ClearGoalDocument = new TypedDocumentString(`
    mutation ClearGoal($input: ClearGoalInput!) {
  clearGoal(input: $input) {
    cleared
  }
}
    `) as unknown as TypedDocumentString<ClearGoalMutation, ClearGoalMutationVariables>;
export const RenameThreadDocument = new TypedDocumentString(`
    mutation RenameThread($id: ID!, $input: RenameThreadInput) {
  renameThread(id: $id, input: $input) {
    result {
      id
      kernelThreadId
      title
      preview
      handle
      onDuty
      cwd
      modelSlug
      reasoningEffort
      webSearch
      agentPath
      status
      lastActivityAt
      insertedAt
      updatedAt
      projectId
      parentThreadId
    }
  }
}
    `) as unknown as TypedDocumentString<RenameThreadMutation, RenameThreadMutationVariables>;
export const SetThreadHandleDocument = new TypedDocumentString(`
    mutation SetThreadHandle($input: SetThreadHandleInput!) {
  setThreadHandle(input: $input) {
    id
    kernelThreadId
    title
    preview
    handle
    onDuty
    cwd
    modelSlug
    reasoningEffort
    webSearch
    agentPath
    status
    lastActivityAt
    insertedAt
    updatedAt
    projectId
    parentThreadId
  }
}
    `) as unknown as TypedDocumentString<SetThreadHandleMutation, SetThreadHandleMutationVariables>;
export const SetThreadOnDutyDocument = new TypedDocumentString(`
    mutation SetThreadOnDuty($input: SetThreadOnDutyInput!) {
  setThreadOnDuty(input: $input) {
    id
    kernelThreadId
    title
    preview
    handle
    onDuty
    cwd
    modelSlug
    reasoningEffort
    webSearch
    agentPath
    status
    lastActivityAt
    insertedAt
    updatedAt
    projectId
    parentThreadId
  }
}
    `) as unknown as TypedDocumentString<SetThreadOnDutyMutation, SetThreadOnDutyMutationVariables>;
export const ArchiveThreadDocument = new TypedDocumentString(`
    mutation ArchiveThread($id: ID!) {
  archiveThread(id: $id) {
    result {
      id
      kernelThreadId
      title
      preview
      handle
      onDuty
      cwd
      modelSlug
      reasoningEffort
      webSearch
      agentPath
      status
      lastActivityAt
      insertedAt
      updatedAt
      projectId
      parentThreadId
    }
  }
}
    `) as unknown as TypedDocumentString<ArchiveThreadMutation, ArchiveThreadMutationVariables>;
export const DeleteThreadDocument = new TypedDocumentString(`
    mutation DeleteThread($input: DeleteThreadInput!) {
  deleteThread(input: $input)
}
    `) as unknown as TypedDocumentString<DeleteThreadMutation, DeleteThreadMutationVariables>;
export const WriteFileDocument = new TypedDocumentString(`
    mutation WriteFile($input: WriteFileInput!) {
  writeFile(input: $input)
}
    `) as unknown as TypedDocumentString<WriteFileMutation, WriteFileMutationVariables>;
export const CreateEntryDocument = new TypedDocumentString(`
    mutation CreateEntry($input: CreateEntryInput!) {
  createEntry(input: $input) {
    size
    path
    name
    kind
  }
}
    `) as unknown as TypedDocumentString<CreateEntryMutation, CreateEntryMutationVariables>;
export const RenameEntryDocument = new TypedDocumentString(`
    mutation RenameEntry($input: RenameEntryInput!) {
  renameEntry(input: $input) {
    size
    path
    name
    kind
  }
}
    `) as unknown as TypedDocumentString<RenameEntryMutation, RenameEntryMutationVariables>;
export const DeleteEntryDocument = new TypedDocumentString(`
    mutation DeleteEntry($input: DeleteEntryInput!) {
  deleteEntry(input: $input)
}
    `) as unknown as TypedDocumentString<DeleteEntryMutation, DeleteEntryMutationVariables>;
export const GitCommitDocument = new TypedDocumentString(`
    mutation GitCommit($input: GitCommitInput!) {
  gitCommit(input: $input) {
    sha
  }
}
    `) as unknown as TypedDocumentString<GitCommitMutation, GitCommitMutationVariables>;
export const GitDiscardDocument = new TypedDocumentString(`
    mutation GitDiscard($input: GitDiscardInput!) {
  gitDiscard(input: $input)
}
    `) as unknown as TypedDocumentString<GitDiscardMutation, GitDiscardMutationVariables>;
export const GitUndoCommitDocument = new TypedDocumentString(`
    mutation GitUndoCommit($input: GitUndoCommitInput!) {
  gitUndoCommit(input: $input) {
    sha
  }
}
    `) as unknown as TypedDocumentString<GitUndoCommitMutation, GitUndoCommitMutationVariables>;
export const GitAbortMergeDocument = new TypedDocumentString(`
    mutation GitAbortMerge($input: GitAbortMergeInput!) {
  gitAbortMerge(input: $input)
}
    `) as unknown as TypedDocumentString<GitAbortMergeMutation, GitAbortMergeMutationVariables>;
export const GitCreateBranchDocument = new TypedDocumentString(`
    mutation GitCreateBranch($input: GitCreateBranchInput!) {
  gitCreateBranch(input: $input)
}
    `) as unknown as TypedDocumentString<GitCreateBranchMutation, GitCreateBranchMutationVariables>;
export const GitSwitchDocument = new TypedDocumentString(`
    mutation GitSwitch($input: GitSwitchInput!) {
  gitSwitch(input: $input)
}
    `) as unknown as TypedDocumentString<GitSwitchMutation, GitSwitchMutationVariables>;
export const GitDeleteBranchDocument = new TypedDocumentString(`
    mutation GitDeleteBranch($input: GitDeleteBranchInput!) {
  gitDeleteBranch(input: $input)
}
    `) as unknown as TypedDocumentString<GitDeleteBranchMutation, GitDeleteBranchMutationVariables>;
export const GitStashPopDocument = new TypedDocumentString(`
    mutation GitStashPop($input: GitStashPopInput!) {
  gitStashPop(input: $input)
}
    `) as unknown as TypedDocumentString<GitStashPopMutation, GitStashPopMutationVariables>;
export const GitSetRemoteDocument = new TypedDocumentString(`
    mutation GitSetRemote($input: GitSetRemoteInput!) {
  gitSetRemote(input: $input)
}
    `) as unknown as TypedDocumentString<GitSetRemoteMutation, GitSetRemoteMutationVariables>;
export const GitFetchDocument = new TypedDocumentString(`
    mutation GitFetch($input: GitFetchInput!) {
  gitFetch(input: $input)
}
    `) as unknown as TypedDocumentString<GitFetchMutation, GitFetchMutationVariables>;
export const GitPullDocument = new TypedDocumentString(`
    mutation GitPull($input: GitPullInput!) {
  gitPull(input: $input)
}
    `) as unknown as TypedDocumentString<GitPullMutation, GitPullMutationVariables>;
export const GitPushDocument = new TypedDocumentString(`
    mutation GitPush($input: GitPushInput!) {
  gitPush(input: $input)
}
    `) as unknown as TypedDocumentString<GitPushMutation, GitPushMutationVariables>;
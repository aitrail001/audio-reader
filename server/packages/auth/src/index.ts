export const packageId = "@audio-reader/auth" as const;

export { createFakePrincipal, type Principal, type PrincipalRole } from "./principal";
export {
  LOCAL_JWT_CONFIG,
  extractBearerToken,
  signAccessToken,
  validateAccessToken,
  type JwtClaims,
  type JwtFailureCode,
  type JwtSigningConfig,
  type JwtValidationResult,
  type SignAccessTokenClaims,
} from "./jwt";
export {
  AUTH_PROVIDERS,
  createMemoryAuthService,
  normalizeEmail,
  type AuthFailureCode,
  type AuthProviderId,
  type AuthResult,
  type AuthService,
  type AuthenticatedSession,
  type BootstrapDeviceInput,
  type BootstrapSession,
  type IdentityProvider,
  type LinkIdentityInput,
  type MemoryAuthServiceOptions,
  type OAuthAuthorizeInput,
  type OAuthExchangeInput,
  type OAuthProvider,
  type ProductDevice,
  type ProductProfile,
  type ProductSettings,
  type SessionTokens,
} from "./service";

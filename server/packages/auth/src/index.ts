export const packageId = "@audio-reader/auth" as const;

export type PrincipalRole = "user" | "admin";

export type Principal = {
  subject: string;
  profileId: string;
  role: PrincipalRole;
};

export function createFakePrincipal(overrides: Partial<Principal> = {}): Principal {
  return {
    subject: overrides.subject ?? "fake-subject",
    profileId: overrides.profileId ?? "00000000-0000-4000-8000-000000000001",
    role: overrides.role ?? "user",
  };
}

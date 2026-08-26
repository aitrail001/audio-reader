export type PrincipalRole = "user" | "admin";

export type Principal = {
  subject: string;
  profileId: string;
  accountId: string;
  role: PrincipalRole;
  email: string;
};

export function createFakePrincipal(overrides: Partial<Principal> = {}): Principal {
  return {
    subject: overrides.subject ?? "fake-subject",
    profileId: overrides.profileId ?? "00000000-0000-4000-8000-000000000001",
    accountId: overrides.accountId ?? "00000000-0000-4000-8000-000000000002",
    role: overrides.role ?? "user",
    email: overrides.email ?? "fake@example.com",
  };
}

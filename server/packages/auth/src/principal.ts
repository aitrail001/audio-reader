export type PrincipalRole = "user" | "admin";

export type AdminRole =
  "support_readonly" | "operator" | "privacy_officer" | "billing_operator" | "superadmin";

export type Principal = {
  subject: string;
  profileId: string;
  accountId: string;
  role: PrincipalRole;
  adminRoles: readonly AdminRole[];
  email: string;
};

export function createFakePrincipal(overrides: Partial<Principal> = {}): Principal {
  const role = overrides.role ?? "user";
  return {
    subject: overrides.subject ?? "fake-subject",
    profileId: overrides.profileId ?? "00000000-0000-4000-8000-000000000001",
    accountId: overrides.accountId ?? "00000000-0000-4000-8000-000000000002",
    role,
    adminRoles: overrides.adminRoles ?? (role === "admin" ? ["superadmin"] : []),
    email: overrides.email ?? "fake@example.com",
  };
}

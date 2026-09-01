import { describe, expect, it } from "vitest";
import { dockerPsqlArgs, isTransientPostgresError } from "./postgres-harness";

describe("postgres harness", () => {
  it("uses TCP inside Docker so psql does not depend on the init unix socket", () => {
    const args = dockerPsqlArgs("audio-reader-rls-1");
    expect(args).toContain("exec");
    expect(args).toContain("psql");
    const hostIndex = args.indexOf("-h");
    expect(hostIndex).toBeGreaterThanOrEqual(0);
    expect(args[hostIndex + 1]).toBe("127.0.0.1");
    expect(args).not.toContain("/var/run/postgresql");
  });

  it("retries the Docker init socket race and refused connections", () => {
    expect(
      isTransientPostgresError(
        'psql: error: connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed: No such file or directory',
      ),
    ).toBe(true);
    expect(
      isTransientPostgresError(
        'psql: error: connection to server at "127.0.0.1" failed: Connection refused',
      ),
    ).toBe(true);
    expect(isTransientPostgresError("FATAL:  the database system is starting up")).toBe(true);
    expect(isTransientPostgresError("ERROR:  relation books does not exist")).toBe(false);
    expect(isTransientPostgresError("open /missing.sql: no such file or directory")).toBe(false);
  });
});

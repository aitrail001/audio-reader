export type UniqueConstraint = {
  columns: string[];
  nullsNotDistinct: boolean;
  deferrable: boolean;
};

export type TableDefinition = {
  columns: Map<string, string>;
  constraints: string[];
  uniques: UniqueConstraint[];
};

export type ForeignKey = {
  table: string;
  columns: string[];
  refTable: string;
  refColumns: string[];
  onDelete: string | undefined;
};

export type IndexDefinition = {
  name: string;
  table: string;
  unique: boolean;
  columns: string[];
  where: string | undefined;
  nullsNotDistinct: boolean;
};

export type ParsedSchema = {
  tables: Map<string, TableDefinition>;
  foreignKeys: ForeignKey[];
  indexes: IndexDefinition[];
  hasUnique(table: string, columns: readonly string[]): boolean;
  hasIndex(table: string, columns: readonly string[]): boolean;
  hasCheck(table: string, column: string): boolean;
};

const CONSTRAINT_START = /^(constraint|check|unique|primary|foreign|exclude|like)\b/i;

export function parsePostgresSchema(sql: string): ParsedSchema {
  const stripped = stripSqlComments(sql);
  const statements = splitStatements(stripped);
  const tables = new Map<string, TableDefinition>();
  const foreignKeys: ForeignKey[] = [];
  const indexes: IndexDefinition[] = [];

  for (const statement of statements) {
    const createTable =
      /^create\s+table(?:\s+if\s+not\s+exists)?\s+(?:public\.)?([a-z_][a-z0-9_]*)\s*\(/i.exec(
        statement,
      );
    if (createTable?.[1] !== undefined) {
      const open = statement.indexOf("(");
      const close = matchingParen(statement, open);
      const body = statement.slice(open + 1, close);
      const table = parseTableBody(body);
      tables.set(createTable[1], table);
      for (const fk of tableForeignKeys(createTable[1], table)) {
        foreignKeys.push(fk);
      }
      continue;
    }

    const alter =
      /^alter\s+table(?:\s+only)?\s+(?:public\.)?([a-z_][a-z0-9_]*)\s+add(?:\s+constraint\s+[a-z_][a-z0-9_]*)?\s+(.*)$/is.exec(
        statement,
      );
    if (alter?.[1] !== undefined && alter[2] !== undefined) {
      const tableName = alter[1];
      const table = tables.get(tableName);
      if (table !== undefined) {
        table.constraints.push(collapse(alter[2]));
      }
      for (const fk of parseForeignKeys(tableName, alter[2])) {
        foreignKeys.push(fk);
      }
      const unique = parseUniqueConstraint(alter[2]);
      if (unique !== undefined && table !== undefined) {
        table.uniques.push(unique);
      }
      continue;
    }

    const index =
      /^create\s+(unique\s+)?index(?:\s+if\s+not\s+exists)?\s+([a-z_][a-z0-9_]*)\s+on\s+(?:public\.)?([a-z_][a-z0-9_]*)\s*\(([^)]*)\)(?:\s+nulls\s+(not\s+)?distinct)?(?:\s+where\s+(.*))?$/is.exec(
        statement,
      );
    if (index?.[2] !== undefined && index[3] !== undefined && index[4] !== undefined) {
      indexes.push({
        name: index[2],
        table: index[3],
        unique: Boolean(index[1]),
        columns: splitIdentifierList(index[4]),
        where: index[6]?.trim(),
        nullsNotDistinct: /\bnulls\s+not\s+distinct\b/i.test(statement),
      });
    }
  }

  return {
    tables,
    foreignKeys,
    indexes,
    hasUnique(table, columns) {
      return hasColumnList(uniqueColumnLists(tables.get(table), indexes, table), columns);
    },
    hasIndex(table, columns) {
      const lists = [
        ...uniqueColumnLists(tables.get(table), indexes, table),
        ...indexes.filter((index) => index.table === table).map((index) => index.columns),
      ];
      return hasColumnList(lists, columns);
    },
    hasCheck(table, column) {
      const definition = tables.get(table);
      if (definition === undefined) {
        return false;
      }
      const columnSql = definition.columns.get(column) ?? "";
      if (/\bcheck\s*\(/i.test(columnSql)) {
        return true;
      }
      const needle = column.toLowerCase();
      return definition.constraints.some(
        (constraint) =>
          /\bcheck\s*\(/i.test(constraint) && constraint.toLowerCase().includes(needle),
      );
    },
  };
}

function uniqueColumnLists(
  table: TableDefinition | undefined,
  indexes: IndexDefinition[],
  tableName: string,
): string[][] {
  const lists: string[][] = [];
  if (table !== undefined) {
    for (const [name, definition] of table.columns) {
      if (/\bunique\b/i.test(definition)) {
        lists.push([name]);
      }
    }
    for (const unique of table.uniques) {
      lists.push(unique.columns);
    }
  }
  for (const index of indexes) {
    if (index.table === tableName && index.unique) {
      lists.push(index.columns);
    }
  }
  return lists;
}

function hasColumnList(lists: string[][], columns: readonly string[]): boolean {
  const wanted = columns.map((column) => column.toLowerCase());
  return lists.some((list) => {
    const have = list.map((column) => column.toLowerCase());
    if (wanted.length === 1) {
      return have.includes(wanted[0] ?? "");
    }
    return wanted.every((column, index) => have[index] === column);
  });
}

function parseTableBody(body: string): TableDefinition {
  const columns = new Map<string, string>();
  const constraints: string[] = [];
  const uniques: UniqueConstraint[] = [];
  for (const part of splitTopLevel(body, ",")) {
    const item = collapse(part);
    if (item.length === 0) {
      continue;
    }
    if (CONSTRAINT_START.test(item)) {
      constraints.push(item);
      const unique = parseUniqueConstraint(item);
      if (unique !== undefined) {
        uniques.push(unique);
      }
      continue;
    }
    const name = item.match(/^[a-z_][a-z0-9_]*/i)?.[0];
    if (name === undefined) {
      constraints.push(item);
      continue;
    }
    columns.set(name, item.slice(name.length).trim());
  }
  return { columns, constraints, uniques };
}

function tableForeignKeys(table: string, definition: TableDefinition): ForeignKey[] {
  const keys: ForeignKey[] = [];
  for (const [column, sql] of definition.columns) {
    keys.push(...parseForeignKeys(table, `${column} ${sql}`, [column]));
  }
  for (const constraint of definition.constraints) {
    keys.push(...parseForeignKeys(table, constraint));
  }
  return keys;
}

function parseForeignKeys(table: string, sql: string, implicitColumns?: string[]): ForeignKey[] {
  const keys: ForeignKey[] = [];
  const tableLevel =
    /foreign\s+key\s*\(([^)]+)\)\s*references\s+(?:public\.)?([a-z_][a-z0-9_]*)\s*(?:\(([^)]+)\))?/gi;
  let match = tableLevel.exec(sql);
  while (match !== null) {
    const columns = splitIdentifierList(match[1] ?? "");
    const refTable = match[2];
    if (refTable !== undefined && columns.length > 0) {
      keys.push({
        table,
        columns,
        refTable,
        refColumns: splitIdentifierList(match[3] ?? columns.join(", ")),
        onDelete: parseOnDelete(sql),
      });
    }
    match = tableLevel.exec(sql);
  }
  if (keys.length > 0) {
    return keys;
  }
  const columnLevel = /references\s+(?:public\.)?([a-z_][a-z0-9_]*)\s*(?:\(([^)]+)\))?/gi;
  match = columnLevel.exec(sql);
  while (match !== null) {
    const refTable = match[1];
    if (refTable !== undefined) {
      keys.push({
        table,
        columns: implicitColumns ?? [],
        refTable,
        refColumns: splitIdentifierList(match[2] ?? ""),
        onDelete: parseOnDelete(sql),
      });
    }
    match = columnLevel.exec(sql);
  }
  return keys;
}

function parseUniqueConstraint(sql: string): UniqueConstraint | undefined {
  const match = /\bunique(?:\s+nulls\s+(?:not\s+)?distinct)?\s*\(([^)]+)\)/i.exec(sql);
  if (match?.[1] === undefined) {
    return undefined;
  }
  return {
    columns: splitIdentifierList(match[1]),
    nullsNotDistinct: /\bnulls\s+not\s+distinct\b/i.test(sql),
    deferrable: /\bdeferrable\b/i.test(sql),
  };
}

function parseOnDelete(sql: string): string | undefined {
  const match = /on\s+delete\s+(cascade|set\s+null|set\s+default|restrict|no\s+action)/i.exec(sql);
  return match?.[1]?.toLowerCase().replace(/\s+/g, " ");
}

function splitIdentifierList(value: string): string[] {
  return value
    .split(",")
    .map((part) => part.trim().replace(/["]/g, "").split(/\s+/)[0] ?? "")
    .filter((part) => part.length > 0);
}

function charAt(sql: string, index: number): string {
  return sql[index] ?? "";
}

function splitStatements(sql: string): string[] {
  const statements: string[] = [];
  let current = "";
  let i = 0;
  let dollar: string | undefined;
  let inSingle = false;
  while (i < sql.length) {
    const ch = charAt(sql, i);
    if (dollar !== undefined) {
      if (sql.startsWith(dollar, i)) {
        current += dollar;
        i += dollar.length;
        dollar = undefined;
        continue;
      }
      current += ch;
      i += 1;
      continue;
    }
    if (inSingle) {
      current += ch;
      if (ch === "'" && sql[i + 1] === "'") {
        current += "'";
        i += 2;
        continue;
      }
      if (ch === "'") {
        inSingle = false;
      }
      i += 1;
      continue;
    }
    if (ch === "'") {
      inSingle = true;
      current += ch;
      i += 1;
      continue;
    }
    if (ch === "$") {
      const tag = sql.slice(i).match(/^\$[a-zA-Z0-9_]*\$/);
      if (tag?.[0] !== undefined) {
        dollar = tag[0];
        current += tag[0];
        i += tag[0].length;
        continue;
      }
    }
    if (ch === ";") {
      const trimmed = collapse(current);
      if (trimmed.length > 0) {
        statements.push(trimmed);
      }
      current = "";
      i += 1;
      continue;
    }
    current += ch;
    i += 1;
  }
  const trailing = collapse(current);
  if (trailing.length > 0) {
    statements.push(trailing);
  }
  return statements;
}

function splitTopLevel(sql: string, delimiter: string): string[] {
  const parts: string[] = [];
  let current = "";
  let depth = 0;
  let inSingle = false;
  for (let i = 0; i < sql.length; i += 1) {
    const ch = charAt(sql, i);
    if (inSingle) {
      current += ch;
      if (ch === "'" && sql[i + 1] === "'") {
        current += "'";
        i += 1;
        continue;
      }
      if (ch === "'") {
        inSingle = false;
      }
      continue;
    }
    if (ch === "'") {
      inSingle = true;
      current += ch;
      continue;
    }
    if (ch === "(") {
      depth += 1;
      current += ch;
      continue;
    }
    if (ch === ")") {
      depth -= 1;
      current += ch;
      continue;
    }
    if (ch === delimiter && depth === 0) {
      parts.push(current);
      current = "";
      continue;
    }
    current += ch;
  }
  if (current.trim().length > 0) {
    parts.push(current);
  }
  return parts;
}

function matchingParen(sql: string, openIndex: number): number {
  let depth = 0;
  let inSingle = false;
  for (let i = openIndex; i < sql.length; i += 1) {
    const ch = charAt(sql, i);
    if (inSingle) {
      if (ch === "'" && sql[i + 1] === "'") {
        i += 1;
        continue;
      }
      if (ch === "'") {
        inSingle = false;
      }
      continue;
    }
    if (ch === "'") {
      inSingle = true;
      continue;
    }
    if (ch === "(") {
      depth += 1;
    } else if (ch === ")") {
      depth -= 1;
      if (depth === 0) {
        return i;
      }
    }
  }
  return sql.length;
}

function stripSqlComments(sql: string): string {
  let out = "";
  let i = 0;
  let inSingle = false;
  let dollar: string | undefined;
  while (i < sql.length) {
    const ch = charAt(sql, i);
    if (dollar !== undefined) {
      if (sql.startsWith(dollar, i)) {
        out += dollar;
        i += dollar.length;
        dollar = undefined;
        continue;
      }
      out += ch;
      i += 1;
      continue;
    }
    if (inSingle) {
      out += ch;
      if (ch === "'" && sql[i + 1] === "'") {
        out += "'";
        i += 2;
        continue;
      }
      if (ch === "'") {
        inSingle = false;
      }
      i += 1;
      continue;
    }
    if (ch === "'") {
      inSingle = true;
      out += ch;
      i += 1;
      continue;
    }
    if (ch === "$") {
      const tag = sql.slice(i).match(/^\$[a-zA-Z0-9_]*\$/);
      if (tag?.[0] !== undefined) {
        dollar = tag[0];
        out += tag[0];
        i += tag[0].length;
        continue;
      }
    }
    if (ch === "-" && sql[i + 1] === "-") {
      while (i < sql.length && sql[i] !== "\n") {
        i += 1;
      }
      out += "\n";
      continue;
    }
    if (ch === "/" && sql[i + 1] === "*") {
      i += 2;
      while (i < sql.length && !(sql[i] === "*" && sql[i + 1] === "/")) {
        i += 1;
      }
      i += 2;
      out += " ";
      continue;
    }
    out += ch;
    i += 1;
  }
  return out;
}

function collapse(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

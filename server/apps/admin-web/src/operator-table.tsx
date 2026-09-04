import { Fragment, useMemo, useState, type ReactNode } from "react";
import { rowCountLabel } from "./format";

export type OperatorColumn<T> = {
  id: string;
  header: string;
  numeric?: boolean;
  sortValue?: (row: T) => string | number;
  searchValue?: (row: T) => string;
  render: (row: T) => ReactNode;
};

type SortDir = "asc" | "desc";

function compareValues(left: string | number, right: string | number): number {
  if (typeof left === "number" && typeof right === "number") {
    return left - right;
  }
  return String(left).localeCompare(String(right), undefined, {
    numeric: true,
    sensitivity: "base",
  });
}

function cellSearch(column: OperatorColumn<unknown>, row: unknown): string {
  if (column.searchValue !== undefined) {
    return column.searchValue(row);
  }
  if (column.sortValue !== undefined) {
    return String(column.sortValue(row));
  }
  return "";
}

export function OperatorTable<T>(props: {
  caption: string;
  noun: string;
  plural?: string;
  rows: T[];
  columns: OperatorColumn<T>[];
  rowKey: (row: T) => string;
  empty: string;
  leading?: ReactNode;
  expandedId?: string | null;
  renderExpand?: (row: T) => ReactNode;
}) {
  const [query, setQuery] = useState("");
  const [sortId, setSortId] = useState<string | null>(null);
  const [sortDir, setSortDir] = useState<SortDir>("asc");

  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase();
    if (needle === "") {
      return props.rows;
    }
    return props.rows.filter((row) =>
      props.columns.some((column) =>
        cellSearch(column as OperatorColumn<unknown>, row)
          .toLowerCase()
          .includes(needle),
      ),
    );
  }, [props.columns, props.rows, query]);

  const visible = useMemo(() => {
    if (sortId === null) {
      return filtered;
    }
    const column = props.columns.find((item) => item.id === sortId);
    const sortValue = column?.sortValue;
    if (sortValue === undefined) {
      return filtered;
    }
    const copy = [...filtered];
    copy.sort((left, right) => {
      const result = compareValues(sortValue(left), sortValue(right));
      return sortDir === "asc" ? result : -result;
    });
    return copy;
  }, [filtered, props.columns, sortDir, sortId]);

  function toggleSort(column: OperatorColumn<T>): void {
    if (column.sortValue === undefined) {
      return;
    }
    if (sortId !== column.id) {
      setSortId(column.id);
      setSortDir(column.numeric === true ? "desc" : "asc");
      return;
    }
    if (sortDir === "asc") {
      setSortDir("desc");
      return;
    }
    setSortId(null);
    setSortDir("asc");
  }

  return (
    <div className="operator-grid">
      <div className="grid-toolbar">
        {props.leading !== undefined ? <div className="grid-filters">{props.leading}</div> : null}
        <div className="grid-find">
          <p className="table-meta">
            {query.trim() === ""
              ? rowCountLabel(props.rows.length, props.noun, props.plural)
              : `${String(visible.length)} of ${rowCountLabel(props.rows.length, props.noun, props.plural)}`}
          </p>
          <label>
            Find in this page
            <input
              value={query}
              placeholder="Name, id, or status"
              onChange={(event) => {
                setQuery(event.target.value);
              }}
            />
          </label>
        </div>
      </div>
      {visible.length === 0 ? (
        <p className="empty">{props.empty}</p>
      ) : (
        <div className="scroll-table">
          <table className="data">
            <caption>{props.caption}</caption>
            <thead>
              <tr>
                {props.columns.map((column) => {
                  const sortable = column.sortValue !== undefined;
                  const active = sortId === column.id;
                  const ariaSort = !sortable
                    ? undefined
                    : active
                      ? sortDir === "asc"
                        ? "ascending"
                        : "descending"
                      : "none";
                  return (
                    <th
                      key={column.id}
                      className={column.numeric === true ? "num" : undefined}
                      aria-sort={ariaSort}
                    >
                      {sortable ? (
                        <button
                          type="button"
                          className="sort"
                          aria-label={
                            active
                              ? `${column.header}, sorted ${sortDir === "asc" ? "ascending" : "descending"}`
                              : `Sort ${column.header}`
                          }
                          onClick={() => {
                            toggleSort(column);
                          }}
                        >
                          {column.header}
                          <svg
                            className={active ? `sort-mark ${sortDir}` : "sort-mark"}
                            viewBox="0 0 12 12"
                            width="10"
                            height="10"
                            aria-hidden="true"
                          >
                            <path
                              className={active && sortDir === "asc" ? "on" : undefined}
                              d="M3 4.5 6 2l3 2.5"
                              fill="none"
                              stroke="currentColor"
                              strokeWidth="1.4"
                              strokeLinecap="round"
                              strokeLinejoin="round"
                            />
                            <path
                              className={active && sortDir === "desc" ? "on" : undefined}
                              d="M3 7.5 6 10l3-2.5"
                              fill="none"
                              stroke="currentColor"
                              strokeWidth="1.4"
                              strokeLinecap="round"
                              strokeLinejoin="round"
                            />
                          </svg>
                        </button>
                      ) : (
                        column.header
                      )}
                    </th>
                  );
                })}
              </tr>
            </thead>
            <tbody>
              {visible.map((row) => {
                const id = props.rowKey(row);
                const open = props.expandedId === id;
                return (
                  <Fragment key={id}>
                    <tr className={open ? "selected" : undefined}>
                      {props.columns.map((column) => (
                        <td key={column.id} className={column.numeric === true ? "num" : undefined}>
                          {column.render(row)}
                        </td>
                      ))}
                    </tr>
                    {open && props.renderExpand !== undefined ? (
                      <tr className="expand">
                        <td colSpan={props.columns.length}>{props.renderExpand(row)}</td>
                      </tr>
                    ) : null}
                  </Fragment>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

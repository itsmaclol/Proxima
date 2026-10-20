# Checks every Proxmox API call in Proxima's Swift sources against a server's own API schema (the API viewer's apidoc.js):
# the path exists, the method exists on it, literal parameter names are ones the server accepts, and edit forms don't
# send `delete` to endpoints that have none. Usage: python3 apicheck.py <apidoc.js> <source folder>
import json, os, re, sys

def load_schema(file):
    src = open(file, encoding="utf-8").read()
    schema, _ = json.JSONDecoder().raw_decode(src[src.index("[", src.index("apiSchema")):])
    index = {}
    def walk(nodes):
        for node in nodes:
            index[node["path"]] = {m: set((((i.get("parameters") or {}).get("properties")) or {}).keys())
                                   for m, i in (node.get("info") or {}).items()}
            walk(node.get("children") or [])
    walk(schema)
    return index

def scan_call(text, start):
    """Raw top-level arguments of the call whose '(' is at text[start], respecting strings and interpolations."""
    args, cur, stack, i = [], [], [], start + 1  # stack holds ')' / ']' / '}' closers and '"' for open strings
    while i < len(text):
        c = text[i]
        top = stack[-1] if stack else None
        if top == '"':
            cur.append(c)
            if c == "\\" and text[i + 1] == "(":
                stack.append(")i"); cur.append("("); i += 2; continue
            if c == "\\":
                cur.append(text[i + 1]); i += 2; continue
            if c == '"':
                stack.pop()
            i += 1; continue
        if c == '"':
            stack.append('"')
        elif c in "([{":
            stack.append({"(": ")", "[": "]", "{": "}"}[c])
        elif c in ")]}":
            if not stack:
                args.append("".join(cur).strip()); return args
            closer = stack.pop()
            if closer == ")i":  # end of an interpolation: back inside the string
                cur.append(c); i += 1; continue
        elif c == "," and not stack:
            args.append("".join(cur).strip()); cur = []; i += 1; continue
        cur.append(c); i += 1
    return args

def split_top(expr, sep):
    """Splits on `sep` outside strings, interpolations and brackets."""
    parts, cur, stack, i = [], [], [], 0  # stack: '"' for an open string, ')i' for an interpolation, other closers
    while i < len(expr):
        c = expr[i]
        top = stack[-1] if stack else None
        if top == '"':
            cur.append(c)
            if c == "\\" and expr[i + 1:i + 2] == "(":
                stack.append(")i"); cur.append("("); i += 2; continue
            if c == "\\":
                cur.append(expr[i + 1:i + 2]); i += 2; continue
            if c == '"':
                stack.pop()
            i += 1; continue
        if c == '"':
            stack.append('"')
        elif c in "([{":
            stack.append({"(": ")", "[": "]", "{": "}"}[c])
        elif c in ")]}" and stack:
            stack.pop()
        elif not stack and expr.startswith(sep, i):
            parts.append("".join(cur)); cur = []; i += len(sep); continue
        cur.append(c); i += 1
    parts.append("".join(cur))
    return [p.strip() for p in parts]

def interpolations(literal, resolve=lambda inner: "{*}"):
    """Replaces each \\(...) in a string literal's body with what `resolve` makes of it ({*} by default)."""
    out, i = [], 0
    while i < len(literal):
        if literal.startswith("\\(", i):
            depth, j, in_str = 1, i + 2, False
            while j < len(literal) and depth:
                c = literal[j]
                if c == '"': in_str = not in_str
                elif not in_str and c == "(": depth += 1
                elif not in_str and c == ")": depth -= 1
                j += 1
            out.append(resolve(literal[i + 2:j - 1].strip())); i = j; continue
        out.append(literal[i]); i += 1
    return "".join(out)

class Source:
    def __init__(self, text):
        self.text = text

    def is_parameter(self, ident, pos):
        """Whether `ident` is a parameter of the function the call sits in (its value comes from callers)."""
        f = self.text.rfind("func ", 0, pos)
        return f >= 0 and re.search(r"\b" + re.escape(ident) + r"\s*:\s*String\b", self.text[f:self.text.find("{", f)]) is not None

    def definition(self, ident, pos):
        """The string literal a path variable is set to, from its nearest definition (preferring one before the call)."""
        if ident.startswith("Self.path("):
            rx = re.compile(r'static func path\([^)]*\)\s*->\s*String\s*\{\s*(".*)$', re.M)
        else:
            rx = re.compile(r'(?:var|let)\s+' + re.escape(ident) + r'(?:\s*:\s*String)?\s*(?:=|\{)\s*(".*)$', re.M)
        found = list(rx.finditer(self.text))
        before = [m for m in found if m.start() < pos]
        m = before[-1] if before else (found[0] if found else None)
        if not m:
            return None
        expr = m.group(1).rstrip()
        return expr[:-1].rstrip() if expr.endswith("}") and not ident.startswith("Self.") or expr.endswith(" }") else expr

    def variable(self, ident, pos, depth):
        """The pattern a path variable stands for."""
        if ident == "scope.base":
            return "{?}/firewall"
        if ident == "rulesPath" or (ident == "base" and "scope.base" in self.text):
            return "{?}"  # a firewall's base (datacenter, node or guest), or a security group
        if self.is_parameter(ident, pos):
            return "{?}"
        d = self.definition(ident, pos) if depth < 3 else None
        return self.pattern(d, pos, depth + 1) if d and d.startswith('"') else None

    def pattern(self, expr, pos, depth=0):
        """A path expression as a pattern: {*} is one segment, {?} any run of segments."""
        out = []
        for part in split_top(expr, " + "):
            if part.startswith('"') and part.endswith('"'):
                def resolve(inner):
                    # A path variable inside a literal ("\(path)/content") stands for its own value; anything else is one segment.
                    if inner in ("scope.base", "rulesPath", "base", "path", "api"):
                        return self.variable(inner, pos, depth) or "{*}"
                    return "{*}"
                out.append(interpolations(part[1:-1], resolve))
            elif re.fullmatch(r"[A-Za-z_][\w.]*(\([^)]*\))?", part) and depth < 3:
                sub = self.variable(part, pos, depth)
                if sub is None:
                    return None
                out.append(sub)
            elif part.startswith("("):
                out.append("{?}")  # an optional suffix such as (name.map { "/\($0)" } ?? "")
            else:
                return None
        return "".join(out)

def matches(app, schema_path):
    if "{?}" in app:
        rx = "^" + re.escape(app).replace(r"\{\?\}", ".*").replace(r"\{\*\}", "[^/]+") + "$"
        return re.match(rx, schema_path) is not None
    a, b = app.strip("/").split("/"), schema_path.strip("/").split("/")
    return len(a) == len(b) and all(x == "{*}" or (y.startswith("{") and y.endswith("}")) or x == y for x, y in zip(a, b))

def dict_keys(expr):
    expr = (expr or "").strip()
    if not (expr.startswith("[") and expr.endswith("]")) or ":" not in expr:
        return None
    return [m.group(1) for e in split_top(expr[1:-1], ",") if (m := re.match(r'"([A-Za-z0-9_\-:.]+)"\s*:', e))]

def allowed(key, names):
    # Indexed parameters such as net0 are declared as net[n].
    return key in names or any(re.fullmatch(re.escape(n).replace(r"\[n\]", r"\d+"), key) for n in names)

CALLS = [  # (regex, method or None to read it from the arguments, path argument, params argument)
    (r"\bclient\.(?:get|list|object|download)\(", "GET", 0, 1),
    (r"\bclient\.post\(", "POST", 0, 1),
    (r"\bclient\.put\(", "PUT", 0, 1),
    (r"\bclient\.delete\(", "DELETE", 0, 1),
    (r"\bclient\.call\(", None, 1, 2),
    (r"\bclient\.upload\(", "POST", 0, "fields"),
    (r"(?<![\w.])(?:session\.|self\.)?run\(", None, 2, 3),
    (r"(?<![\w.])(?:session\.|self\.)?call\(", None, 2, 3),
    (r"\bconfirmDelete\(", "DELETE", "path", "params"),
    (r"\bopenSPICE\(", "POST", 0, None),
    (r"\bResourceList\(", "GET", "path", "query"),
]

def main():
    index, root = load_schema(sys.argv[1]), sys.argv[2]
    problems, checked, skipped = [], 0, []
    for folder, _, names in os.walk(root):
        for name in sorted(names):
            if not name.endswith(".swift") or name == "ProxmoxClient.swift":
                continue
            file = os.path.join(folder, name)
            source = Source(open(file, encoding="utf-8").read())
            text = source.text
            for rx, method, path_at, params_at in CALLS:
                for m in re.finditer(rx, text):
                    if re.search(r"func\s*$", text[max(0, m.start() - 12):m.start()]):
                        continue  # a declaration, not a call
                    args = scan_call(text, m.end() - 1)
                    labeled, positional = {}, []
                    for a in args:
                        lm = re.match(r"^([A-Za-z_]\w*)\s*:\s*(.*)$", a, re.S)
                        if lm and not a.startswith('"'): labeled[lm.group(1)] = lm.group(2)
                        else: positional.append(a)
                    pick = lambda at: labeled.get(at) if isinstance(at, str) else (positional[at] if at is not None and at < len(positional) else None)
                    meth = method
                    if meth is None:
                        verb = next((a for a in positional if re.fullmatch(r"\.(get|post|put|delete)", a)), None)
                        if not verb:
                            continue  # another function that happens to be called run or call
                        meth = verb[1:].upper()
                    expr = pick(path_at)
                    if not expr:
                        continue
                    where = f"{os.path.relpath(file, root)}:{text.count(chr(10), 0, m.start()) + 1}"
                    pattern = source.pattern(expr, m.start())
                    if pattern is None or not pattern.startswith(("/", "{?}")):
                        skipped.append(f"{where}  {meth} {expr[:80]}"); continue
                    checked += 1
                    hits = [p for p in index if matches(pattern, p)]
                    if not hits:
                        problems.append(f"no such path      {where}  {meth} {pattern}"); continue
                    hits = [p for p in hits if meth in index[p]]
                    if not hits:
                        problems.append(f"no {meth} method  {where}  {pattern}"); continue
                    names_ok = set().union(*(index[p][meth] for p in hits))
                    params = pick(params_at) or ""
                    unknown = [k for k in (dict_keys(params) or []) if not allowed(k, names_ok)]
                    if unknown:
                        problems.append(f"unknown parameter {where}  {meth} {hits[0]}: {', '.join(unknown)}")
                    # Edit forms send Proxmox's `delete` for cleared fields; some endpoints (users, DNS) have none.
                    region = text[max(text.rfind("{ result in", 0, m.start()), m.start() - 1500):m.start()]
                    sends_delete = "result.params" in params or (params == "params" and ("= result.params" in region or 'params["delete"]' in region))
                    if meth == "PUT" and sends_delete and "delete" not in names_ok:
                        problems.append(f"sends delete      {where}  {meth} {hits[0]} (the server has no delete parameter here)")
    print(f"Checked {checked} API calls against {len(index)} paths in the server's schema.")
    for p in problems: print("FAIL", p)
    for s in skipped: print("skip (path built at run time)", s)
    print("ALL CALLS MATCH THE SERVER'S API" if not problems else f"{len(problems)} PROBLEMS")
    sys.exit(1 if problems else 0)

if __name__ == "__main__":
    main()

# SPDX-License-Identifier: Apache-2.0
"""Typed semantic scenarios and paired, structure-preserving metamorphisms.

This is deliberately not a second borrow checker. The reference DAG oracle only
knows possible owner indices, a selected runtime owner, and where the final use
occurs. Other scenarios have small explicit contracts from Xen's documentation.
"""
from __future__ import annotations

from dataclasses import dataclass, replace, asdict
from collections import Counter
from itertools import product
from pathlib import Path
import json
import random

from grammar import Program
from props import check_program, run_program


@dataclass(frozen=True)
class RefExpr:
    kind: str
    index: int = 0
    arms: tuple[RefExpr, ...] = ()

    def origins(self, previous: list[frozenset[int]]) -> frozenset[int]:
        if self.kind == "owner":
            return frozenset([self.index])
        if self.kind == "local":
            return previous[self.index]
        return self.arms[0].origins(previous) | self.arms[1].origins(previous)

    def selected(self, previous: list[int], flags: tuple[bool, ...]) -> int:
        if self.kind == "owner":
            return self.index
        if self.kind == "local":
            return previous[self.index]
        return self.arms[0 if flags[self.index] else 1].selected(previous, flags)

    def source(self, mutable: bool, variant: str = "plain") -> str:
        if self.kind == "owner":
            leaf = f"&{'mut ' if mutable else ''}a{self.index}"
            if variant == "leaf_if":
                return f"if c2{{{leaf}}}else{{{leaf}}}"
            return leaf
        if self.kind == "local":
            return f"r{self.index}"
        a, b = (x.source(mutable,variant) for x in self.arms)
        return f"if c{self.index}{{{a}}}else{{{b}}}"

    def smaller(self):
        if self.kind == "choose":
            yield from self.arms
            for i, arm in enumerate(self.arms):
                for small in arm.smaller():
                    yield replace(self, arms=self.arms[:i] + (small,) + self.arms[i + 1:])


VARIANTS = ("plain", "forward", "if", "match", "blocks", "true", "short", "rhs", "leaf_if")
FAMILIES = ("reference", "slice", "summary", "move", "cleanup", "escape", "capability", "restriction")


@dataclass(frozen=True)
class Scenario:
    family: str
    mutable: bool = False
    action: str = "after"
    nodes: tuple[RefExpr, ...] = ()
    flags: tuple[bool, ...] = (True, False, True)
    target: int = 0
    loops: bool = False
    indirect: bool = False
    field: str = "left"
    depth: int = 1
    reborrow: bool = False

    def origin_sets(self) -> list[frozenset[int]]:
        out: list[frozenset[int]] = []
        for node in self.nodes:
            out.append(node.origins(out))
        return out

    def accepts(self) -> bool:
        if self.family == "reference":
            overlaps = self.target in self.feasible_origins()
            return not (overlaps and (self.action in ("write", "overlap", "backedge") or
                                      self.action == "read" and self.mutable and not self.reborrow))
        return {"slice": self.action == "after", "summary": self.action == "definite",
                "move": self.action in ("sibling", "refill"), "cleanup": True,
                "escape": self.action == "after", "capability": self.action == "inside",
                "restriction": False}[self.family]

    def feasible_origins(self) -> frozenset[int]:
        # Three Bool inputs make exact *generator* feasibility only eight
        # evaluations. This does not add path-sensitive compiler analysis.
        out=set()
        for flags in product((False,True),repeat=3):
            selected=[]
            for node in self.nodes:
                selected.append(node.selected(selected,flags))
            out.add(selected[-1])
        return frozenset(out)

    def smaller(self):
        # These rewrites keep declarations/type correctness; the oracle is
        # recomputed for each candidate. Never shrink by deleting source text.
        if self.loops:
            yield replace(self, loops=False)
        if self.indirect:
            yield replace(self, indirect=False)
        if self.depth > 1:
            yield replace(self, depth=1)
        if self.family == "reference":
            for i, node in enumerate(self.nodes):
                for small in node.smaller():
                    yield replace(self, nodes=self.nodes[:i] + (small,) + self.nodes[i + 1:])
            if len(self.nodes) > 1:
                # Remove final forwarding/merge node, retaining a valid DAG.
                yield replace(self, nodes=self.nodes[:-1])

    def render(self, variant: str) -> Program:
        assert variant in VARIANTS
        preamble = ""
        stdout = ""
        files = None
        if self.family == "reference":
            aggregate = self.field == "aggregate"
            preamble = "struct Cell{value:Int}" if aggregate else ""
            def owner(i):
                return f"a{i}.value" if aggregate else f"a{i}"
            referent = "out.value" if aggregate else "*out"
            ref_type = "&mut Cell" if aggregate else "&mut Int"
            selected: list[int] = []
            for node in self.nodes:
                selected.append(node.selected(selected, self.flags))
            body = "".join(f"let mut a{i}=" +
                           (f"Cell{{value:{10+i}}}" if aggregate else str(10+i)) + ";" for i in range(3))
            body += "".join(f"let r{i}={node.source(self.mutable,variant)};" for i, node in enumerate(self.nodes))
            parent = f"r{len(self.nodes)-1}"
            if self.reborrow:
                # Same shared child via explicit reborrow or contextual
                # coercion. The parent has no further use in this family.
                shared_type = "&Cell" if aggregate else "&Int"
                expr = f"&*{parent}" if variant in ("forward", "blocks", "true", "leaf_if") else parent
                body += forward(expr, "out", variant, shared_type)
            else:
                body += forward(parent, "out", variant)
            a = f"a{self.target}"
            if self.action == "write":
                body += f"{owner(self.target)}=99;"
            elif self.action == "read":
                body += f"println({owner(self.target)});"
                stdout += f"{10+self.target}\n"
            elif self.action == "overlap":
                body += f"let conflict=&mut {a};println(" + ("conflict.value" if aggregate else "*conflict") + ");"
            rounds = 2 if self.loops else 1
            use = f"{referent}={referent}+1;" if self.action == "through" else ""
            if self.action == "through" and self.indirect:
                use = f"let increment:fn({ref_type})->Unit=bump;increment(out);"
            if variant == "rhs":
                use += f"let observe=(c0&&({referent}=={referent}))||(!c0&&({referent}=={referent}));"
            use += f"println({referent});"
            if self.action == "backedge":
                # The mutation follows an apparent last use but the next
                # iteration uses out again. The loop condition is scalar.
                rounds = 2
                use += f"{owner(self.target)}=99;"
            if rounds > 1:
                use = f"let mut i=0;while i<2{{{use}i=i+1;}}"
            body += use
            for iteration in range(rounds):
                stdout += f"{10+selected[-1]+(iteration+1 if self.action=='through' else 0)}\n"
            body += "".join(f"{owner(i)}={30+i};" for i in range(3))
            body += "println(" + "+".join(owner(i) for i in range(3)) + ");"
            stdout += "93\n"
            body = envelope(body, variant)
            args = ",".join(f"c{i}:Bool" for i in range(3))
            actual = ",".join(str(x).lower() for x in self.flags)
            target = "r.value" if aggregate else "*r"
            helper = f"fn bump(r:{ref_type}){{{target}={target}+1;}}" if self.action == "through" and self.indirect else ""
            source = f"#global[explc]\n{preamble}{helper}fn exercise({args}){{{body}}}fn main(){{exercise({actual});}}"
        elif self.family == "slice":
            preamble = "struct View{items:Slice<Int>,count:Int}"
            body = "let mut a=[1];let b=[2];let s:Slice<Int>=if c0{a.as_slice()}else{b.as_slice()};"
            body += forward("s", "out", variant, "Slice<Int>")
            body += "let v=View{items:out,count:7};let copy=v;"
            if self.action == "write":
                body += "a.push(3);"
            body += "println(copy.items[0]);"
            body += "a.push(3);println(copy.count);"
            stdout = f"{1 if self.flags[0] else 2}\n7\n"
            source = f"{preamble}fn exercise(c0:Bool){{{envelope(body,variant)}}}fn main(){{exercise({str(self.flags[0]).lower()});}}"
        elif self.family == "summary":
            assign = "self.items=s;" if self.action == "definite" else "if c{self.items=s;}"
            if self.loops:
                assign = f"if n==0{{{assign}return;}}self.set(s,c,n-1);"
            preamble = f"struct View{{items:Slice<Int>}}impl View{{fn set(&mut self,s:Slice<Int>,c:Bool,n:Int){{{assign}}}}}"
            body = "let mut a=[1];let b=[2];let mut v=View{items:a.as_slice()};let s:Slice<Int>=b.as_slice();"
            body += forward("s", "out", variant, "Slice<Int>")
            body += "v.set(out,c0,2);a.push(3);println(v.items[0]);"
            source = f"{preamble}fn exercise(c0:Bool){{{envelope(body,variant)}}}fn main(){{exercise(true);}}"
            stdout = "2\n"
        elif self.family == "move":
            preamble = "struct Pair{left:File,right:File}fn take(f:File){}fn all(p:Pair){}"
            preamble += "impl Pair{fn extract(&mut self)->File{return self." + self.field + ";}}"
            body = 'let mut p=Pair{left:open_read("/dev/null"),right:open_read("/dev/null")};'
            body += f"let moved=p.{self.field};"
            if self.indirect:
                body += "let consume:fn(File)->Unit=take;consume(moved);"
            else:
                body += "take(moved);"
            sibling = "right" if self.field == "left" else "left"
            if self.action == "refill":
                # Both paths overwrite; if true with no else is intentionally
                # NOT used as a metamorphism of a definite replacement.
                body += f'if c0{{p.{self.field}=open_read("/dev/null");}}else{{p.{self.field}=open_read("/dev/null");}}'
                body += "let again=p.extract();println(again.is_open());"
            elif self.action == "whole":
                body += "all(p);"
            else:
                field = sibling if self.action == "sibling" else self.field
                body += f"let next=p.{field};println(next.is_open());"
            source = f"{preamble}fn exercise(c0:Bool){{{envelope(body,variant)}}}fn main(){{exercise(true);}}"
            stdout = "true\n"
        elif self.family == "cleanup":
            preamble = 'fn fail()->Result<Int,Int>{return Result.Err(7);}fn take(f:File,n:Int){}struct Pair{file:File,n:Int}'
            pending = 'take(open_read("/dev/null"),fail()?);' if self.indirect else 'let p=Pair{file:open_read("/dev/null"),n:fail()?};'
            preamble += f"fn pending()->Result<Int,Int>{{{envelope(pending,variant)}return Result.Ok(0);}}"
            # Break/continue and normal body exit, pending arguments/fields on
            # ?, replacements, moves, closed-but-initialized values and fd reuse.
            rounds=64 + 32*(self.depth-1)
            iteration = 'let r=pending();let mut f=open_read("/dev/null");let moved=f;f=open_read("/dev/null");'
            if self.mutable:
                iteration += '#scope[explc]{let observe=&moved;assert(observe.is_open());let update=&mut f;update.close();}'
            else:
                iteration += 'f.close();'
            iteration += 'f.close();let fresh=open_read("/dev/null");assert(fresh.is_open());'
            iteration += 'let scratch=[open_read("/dev/null"),open_read("/dev/null")];i=i+1;'
            if self.loops:
                iteration += f"if i%2==0{{continue;}}if i=={rounds-1}{{break;}}"
            iteration = "{"*self.depth + iteration + "}"*self.depth
            body = f"let mut i=0;while i<{rounds}{{{iteration}}}println(i);"
            source = f"{preamble}fn main(){{{envelope(body,variant)}}}"
            stdout = f"{rounds-1 if self.loops else rounds}\n"
        elif self.family == "escape":
            body = "let a=[1];let mut s=a.as_slice();"
            if self.action == "after":
                body += "{let inner=[2];s=inner.as_slice();println(s[0]);}"
                stdout = "2\n"
            else:
                body += "{let inner=[2];s=inner.as_slice();}println(s[0]);"
            source = f"fn main(){{{envelope(body,variant)}}}"
        elif self.family == "capability":
            lib = 'module lib;#global[bb,explc]\nfn answer()->Int{let n=7;let r=&n;let p=raw_alloc_int(1);raw_store_int(p,0,*r);let v=raw_load_int(p,0);raw_free_int(p);return v;}'
            body = "println(lib.answer());#scope[explc]{let n=1;let r=&n;println(*r);}"
            if self.action != "inside":
                body += "let n=2;let r=&n;println(*r);"
            files = {"lib.xen": lib, "app.xen": f"module app;import lib;fn main(){{{envelope(body,variant)}}}"}
            stdout = "7\n1\n"
            source = ""
        else:
            # Explicit negative type restriction: no Vec of borrowed structs,
            # including inferred/annotated/nested forms and conditional values.
            preamble = "struct V{s:Slice<Int>}"
            value = "V{s:a.as_slice()}"
            annotation = ":Vec<V>" if self.mutable or self.indirect else ""
            expr = f"[{value}]"
            if self.depth > 1:
                expr = f"[{expr}]"
                annotation = ":Vec<Vec<V>>" if self.mutable or self.indirect else ""
            if self.indirect:
                expr = f"if true{{{expr}}}else{{{expr}}}"
            body = f"let mut a=[1];let v{annotation}={expr};a.push(2);"
            source = f"{preamble}fn main(){{{envelope(body,variant)}}}"
        return Program(files=files or {"case.xen": source}, entry="app.xen" if files else "case.xen",
                       expected_stdout=stdout, features=frozenset([self.family]), notes=repr(self))


def forward(expr: str, name: str, variant: str, typ: str = "") -> str:
    # Only called for reference/Slice values: bindings copy, never clone/move.
    annotation = f":{typ}" if typ else ""
    if variant == "forward":
        return f"let intermediate{annotation}={expr};let second{annotation}=intermediate;let {name}{annotation}=second;"
    if variant in ("if", "short"):
        condition = "c0&&true" if variant == "short" else "c0"
        return f"let {name}{annotation}=if {condition}{{{expr}}}else{{{expr}}};"
    if variant == "match":
        return f"let {name}{annotation}=match c0{{true=>{expr},false=>{expr}}};"
    return f"let {name}{annotation}={expr};"


def envelope(body: str, variant: str) -> str:
    if variant == "blocks":
        return "{{" + body + "}}"
    if variant == "true":
        # Everything is declared/used inside the branch; there is no definite
        # assignment flowing from a conditional branch to code after it.
        return "if true{" + body + "}"
    return body


def generate(rng: random.Random, index: int) -> Scenario:
    # Cycle families/actions to guarantee safety boundaries in every budget.
    family = FAMILIES[index % len(FAMILIES)]
    turn = index // len(FAMILIES)
    flags = tuple(rng.choice([True, False]) for _ in range(3))
    common = dict(flags=flags, loops=rng.choice([True, False]), indirect=rng.choice([True, False]),
                  depth=rng.randint(1, 3), mutable=rng.choice([True, False]))
    if family == "reference":
        def expr(previous: int, depth: int) -> RefExpr:
            if depth and rng.randrange(3) == 0:
                return RefExpr("choose", rng.randrange(3), (expr(previous,depth-1), expr(previous,depth-1)))
            if previous and rng.choice([True, False]):
                return RefExpr("local", previous-1)
            return RefExpr("owner", rng.randrange(3))
        nodes = [expr(0, 2)]
        # Always merge forwarding with a fresh borrow, repeatedly; this is the
        # main historical provenance-loss stress pattern, not isolated emitters.
        for i in range(1, rng.randint(2, 5)):
            nodes.append(RefExpr("choose", rng.randrange(3), (RefExpr("local", i-1), expr(i, 2))))
        action = ("after", "write", "read", "overlap", "through", "backedge")[turn % 6]
        if action == "through":
            common["mutable"] = True
        reborrow = action != "through" and rng.choice([True, False])
        if reborrow:
            common["mutable"] = True
        scenario = Scenario(family, nodes=tuple(nodes), action=action,
                            field=rng.choice(["scalar", "aggregate"]), reborrow=reborrow, **common)
        return replace(scenario, target=rng.choice(sorted(scenario.feasible_origins())))
    actions = {"slice": ("after","write"), "summary": ("definite","conditional"),
               "move": ("sibling","repeat","refill","whole"), "cleanup": ("after",),
               "escape": ("after","escape"), "capability": ("inside","outside"),
               "restriction": ("forbidden",)}[family]
    return Scenario(family, action=actions[turn % len(actions)], field=rng.choice(["left","right"]), **common)


@dataclass(frozen=True)
class Observation:
    kind: str
    detail: str = ""
    accepted: bool | None = None


def observe(case: Scenario, variant: str) -> Observation:
    prog = case.render(variant)
    try:
        result = check_program(prog)
        if result.status not in (0, 1) or any(x in result.stderr.lower() for x in
                ("fatal error", "assertion failed", "internal error", "semantic ir:", "segmentation")):
            return Observation("compiler_crash", repr(result))
        if result.status == 1:
            if case.family == "restriction":
                valid = "unsupported Vec element type" in result.stderr
            elif case.family == "capability":
                valid = "require" in result.stderr and "explc" in result.stderr
            else:
                valid = any(x in result.stderr for x in ("while it is borrowed", "conflicting borrow:",
                    "conflicting borrow of", "conflicting mutable borrow arguments", "borrowed value escapes its owner scope",
                    "use of moved", "use of dead storage", "cannot move or mutate through a shared reference"))
            if not valid:
                return Observation("generator_error", repr(result), False)
            return Observation("conservative_rejection" if case.accepts() else "rejected", result.stderr, False)
        if not case.accepts():
            # Never execute a program the independent contract marks unsafe.
            return Observation("unsound_acceptance", "check accepted a forbidden operation", True)
        result = run_program(prog, fd_limit=32 if case.family == "cleanup" else None)
        if result.status != 0 or result.stderr or result.stdout != prog.expected_stdout:
            return Observation("runtime_mismatch", f"expected={prog.expected_stdout!r} actual={result!r}", True)
        return Observation("accepted", accepted=True)
    except AssertionError as err:
        return Observation("compiler_timeout", str(err))


def compare(base: Observation, transformed: Observation) -> tuple[str, Observation, Observation] | None:
    # Metamorphic comparison uses actual outcomes, independently of the safety
    # oracle. Unsound acceptance retains priority over disagreements.
    severity = ("unsound_acceptance", "compiler_crash", "compiler_timeout", "runtime_mismatch", "generator_error")
    for kind in severity:
        if any(o.kind == kind for o in (base,transformed)):
            return kind,base,transformed
    if base.accepted != transformed.accepted:
        return "metamorphic_disagreement",base,transformed
    for observation in (base, transformed):
        if observation.kind not in ("accepted", "rejected"):
            return observation.kind, base, transformed
    return None


def failure(case: Scenario, variant: str) -> tuple[str, Observation, Observation] | None:
    base = observe(case, "plain")
    return compare(base, base if variant == "plain" else observe(case, variant))


def minimize(case: Scenario, predicate, budget: int = 40) -> Scenario:
    # A bounded greedy structural reducer, preserving the failure category and
    # the chosen transformation. Candidates recompute origins/runtime oracles.
    while budget > 0:
        for candidate in case.smaller():
            budget -= 1
            if predicate(candidate):
                case = candidate
                break
            if budget <= 0:
                return case
        else:
            return case
    return case


def save_failure(case: Scenario, variant: str, seed: int, index: int, problem) -> Path:
    category = problem[0]
    direction=(problem[1].accepted,problem[2].accepted)
    disagreement=direction[0] != direction[1]
    small = minimize(case, lambda c: (p := failure(c, variant)) is not None and p[0] == category and
                     (p[1].accepted,p[2].accepted) == direction)
    reduced = failure(small,variant)
    directory = Path(__file__).parent / "found_bugs" / f"semantic_{seed}_{index}_{variant}"
    directory.mkdir(parents=True, exist_ok=True)
    for label, scenario in (("original",case),("minimized",small)):
        for shape in ("plain",variant):
            for name, source in scenario.render(shape).files.items():
                (directory / f"{label}_{shape}_{name}").write_text(source)
    (directory / "reproduce.json").write_text(json.dumps({"seed":seed,"index":index,
        "variant":variant,"category":category,"case":asdict(case),"minimized":asdict(small),
        "observations":[asdict(x) for x in problem[1:]],
        "minimized_observations":[asdict(x) for x in reduced[1:]] if reduced is not None else [],
        "minimized_reproduced":reduced is not None,
        "metamorphic_disagreement":disagreement,
        "command":f"python3 tests/property/runner.py --mode semantic --seed {seed} --case {index}"},indent=2))
    return directory


def run_semantic(n: int, seed: int, only_case: int | None = None) -> int:
    rng = random.Random(seed)
    hits: Counter[str] = Counter()
    outcomes: Counter[str] = Counter()
    failures = 0
    print(f"=== Semantic IR scenarios + metamorphisms: seed={seed}, cases={n} ===", flush=True)
    for i in range(n if only_case is None else only_case + 1):
        case = generate(rng, i)
        if only_case is not None and i != only_case:
            continue
        hits[case.family] += 1
        base = observe(case, "plain")
        variants = (VARIANTS if case.family == "reference" else
                    VARIANTS[:-2] if case.family in ("slice","summary") else ("plain","blocks","true"))
        problems=[]
        for variant in variants:
            changed = base if variant == "plain" else observe(case, variant)
            outcomes[changed.kind] += 1
            problem = compare(base,changed)
            if problem:
                problems.append((variant,problem))
        if problems:
            failures += 1
            priority=("unsound_acceptance","compiler_crash","compiler_timeout","runtime_mismatch",
                      "generator_error","metamorphic_disagreement","conservative_rejection")
            variant,problem=min(problems,key=lambda p: priority.index(p[1][0]))
            path = save_failure(case, variant, seed, i, problem)
            print(f"  FAIL case={i} family={case.family} variant={variant} category={problem[0]} saved={path}", flush=True)
        if (i + 1) % 40 == 0:
            print(f"  checked {i+1} scenarios", flush=True)
    print(f"  families={dict(hits)} outcomes={dict(outcomes)} failures={failures}", flush=True)
    return failures

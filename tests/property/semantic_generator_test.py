# SPDX-License-Identifier: Apache-2.0
"""Fast self-tests for the generator/oracle/reducer, with no compiler calls."""
import random
import unittest
from unittest.mock import patch
from pathlib import Path
import tempfile
import json
from dataclasses import replace

from semantic import RefExpr, Scenario, Observation, compare, observe, generate, minimize, save_failure, VARIANTS, FAMILIES
from props import RunResult


class GeneratorTests(unittest.TestCase):
    def test_file_emitters_stay_in_restored_working_directory(self):
        from gen import Ctx, RNG, emit_file, emit_std_fs_io, _finalize
        for emitter in (emit_file, emit_std_fs_io):
            ctx = Ctx(RNG(42))
            emitter(ctx)
            source = _finalize(ctx, set(), False).files['app.xen']
            self.assertNotIn('/tmp/xen_qc', source)
            self.assertIn('"xen_qc_', source)

    def test_origins_and_runtime_selection_are_separate(self):
        a, b = RefExpr("owner",0), RefExpr("owner",1)
        nodes = (RefExpr("choose",0,(a,b)),
                 RefExpr("choose",1,(RefExpr("local",0),RefExpr("owner",2))))
        case = Scenario("reference",nodes=nodes,flags=(False,True,False))
        self.assertEqual(case.origin_sets(), [frozenset([0,1]),frozenset([0,1,2])])
        self.assertIn("11\n93\n", case.render("plain").expected_stdout)
        self.assertTrue(case.accepts())
        self.assertFalse(replace(case,action="write",target=0).accepts())
        self.assertTrue(replace(case,action="read",mutable=False).accepts())
        self.assertFalse(replace(case,action="read",mutable=True).accepts())

    def test_reused_condition_does_not_invent_an_unsafe_path(self):
        a,b=RefExpr("owner",0),RefExpr("owner",1)
        # if c { &a } else { if c { &b } else { &a } }
        node=RefExpr("choose",0,(a,RefExpr("choose",0,(b,a))))
        case=Scenario("reference",nodes=(node,),action="write",target=1)
        self.assertEqual(case.origin_sets()[-1],frozenset([0,1]))
        self.assertEqual(case.feasible_origins(),frozenset([0]))
        self.assertTrue(case.accepts())

    def test_aggregate_reference_preserves_scalar_oracle(self):
        case=Scenario("reference",mutable=True,action="through",indirect=True,
                      nodes=(RefExpr("owner",1),),field="aggregate")
        for variant in VARIANTS:
            prog=case.render(variant)
            self.assertEqual(prog.expected_stdout,"12\n93\n")
            self.assertIn("struct Cell{value:Int}",prog.files[prog.entry])
            self.assertIn("fn(&mut Cell)->Unit",prog.files[prog.entry])
        self.assertTrue(case.accepts())
        self.assertFalse(replace(case,action="write",target=1).accepts())
        generated=[generate(random.Random(i),i*len(FAMILIES)) for i in range(20)]
        self.assertEqual({c.field for c in generated},{"scalar","aggregate"})

    def test_shared_reborrow_model_and_forms(self):
        case=Scenario("reference",mutable=True,reborrow=True,action="read",target=0,
                      nodes=(RefExpr("owner",0),),field="aggregate")
        self.assertTrue(case.accepts())
        self.assertFalse(replace(case,action="write").accepts())
        self.assertFalse(replace(case,action="backedge").accepts())
        self.assertIn("let out:&Cell=r0;",case.render("plain").files["case.xen"])
        self.assertIn("=&*r0;",case.render("forward").files["case.xen"])
        for variant in VARIANTS:
            self.assertEqual(case.render(variant).expected_stdout,"10\n10\n93\n")
        generated=[generate(random.Random(i),i*len(FAMILIES)) for i in range(30)]
        self.assertTrue(any(c.reborrow for c in generated))
        self.assertTrue(all(not c.reborrow or c.mutable for c in generated))

    def test_determinism_and_family_coverage(self):
        left,right=random.Random(20261006),random.Random(20261006)
        cases=[generate(left,i) for i in range(200)]
        self.assertEqual(cases,[generate(right,i) for i in range(200)])
        self.assertEqual(set(c.family for c in cases),set(FAMILIES))
        self.assertTrue(any(c.accepts() for c in cases))
        self.assertTrue(any(not c.accepts() for c in cases))
        for case in cases:
            for variant in VARIANTS:
                prog=case.render(variant)
                self.assertIn(prog.entry,prog.files)
                self.assertEqual(prog.expected_stdout,case.render("plain").expected_stdout)
            for small in case.smaller():
                small.render("plain")  # DAG references remain valid.
                small.accepts()

    def test_shrinker_preserves_predicate_and_terminates(self):
        owner=RefExpr("owner",0)
        case=Scenario("reference",mutable=True,action="write",loops=True,depth=3,
            nodes=(RefExpr("choose",0,(owner,owner)),RefExpr("local",0)))
        small=minimize(case,lambda c: not c.accepts())
        self.assertFalse(small.accepts())
        self.assertEqual(small.nodes,(owner,))
        self.assertFalse(small.loops)
        self.assertEqual(small.depth,1)

    def test_metamorphism_compares_actual_outcomes_before_oracle(self):
        accepted=Observation("accepted",accepted=True)
        conservative=Observation("conservative_rejection",accepted=False)
        unsafe=Observation("unsound_acceptance",accepted=True)
        self.assertEqual(compare(conservative,accepted)[0],"metamorphic_disagreement")
        self.assertEqual(compare(accepted,conservative)[0],"metamorphic_disagreement")
        self.assertEqual(compare(Observation("rejected",accepted=False),unsafe)[0],"unsound_acceptance")

    def test_nonreproducing_timeout_still_saves_artifacts(self):
        case=Scenario("reference",nodes=(RefExpr("owner",0),))
        problem=("compiler_timeout",Observation("compiler_timeout"),Observation("compiler_timeout"))
        with tempfile.TemporaryDirectory() as directory:
            with patch("semantic.__file__",str(Path(directory)/"semantic.py")), patch("semantic.failure",return_value=None):
                path=save_failure(case,"forward",123,0,problem)
                record=json.loads((path/"reproduce.json").read_text())
                self.assertFalse(record["minimized_reproduced"])
                self.assertEqual(record["observations"][0]["kind"],"compiler_timeout")

    def test_storage_analysis_diagnostic_is_not_a_generator_error(self):
        case=Scenario("reference",nodes=(RefExpr("owner",0),))
        for message,kind in (("use of dead storage 'out'","conservative_rejection"),
                             ("borrow target must be a local variable","generator_error")):
            with self.subTest(message=message), patch("semantic.check_program",return_value=RunResult(1,"",message)):
                result=observe(case,"plain")
                self.assertEqual(result.kind,kind)
                self.assertFalse(result.accepted)


if __name__ == "__main__":
    unittest.main()

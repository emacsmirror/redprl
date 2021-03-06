functor RefinerCompositionKit (Sig : MINI_SIGNATURE) =
struct
  structure Kit = RefinerKit (Sig)
  structure Syn = SyntaxView
  structure Abt = RedPrlAbt
  open Abt Kit

  type sign = Sig.sign
  type rule = Lcf.jdg Lcf.tactic
  type catjdg = AJ.jdg
  type opid = Sig.opid

  infixr @@
  infix 1 || #>
  infix 2 >> >: >:? >:+ $$ $# // \ @>
  infix orelse_

  (* adding some helper functions *)
  structure Restriction =
  struct
    open Restriction

    fun makeEq tr H eqs ((m, n), ty) =
      Option.map
        (fn f => makeEqWith tr f H ((m, n), ty))
        (restrict H eqs)

    fun makeEqIfDifferent tr H eqs ((m, n), ty) =
      Option.mapPartial
        (fn f =>
          if Abt.eq (f m, f n) then NONE
          else SOME @@ makeEqWith tr f H ((m, n), ty))
        (restrict H eqs)

    fun makeMem tr eqs H (m, ty) =
      makeEq tr eqs H ((m, m), ty)

    fun makeEqType tr H eqs ((a, b), k) =
      Option.map
        (fn f => makeEqTypeWith tr f H ((a, b), k))
        (restrict H eqs)

    fun makeEqTypeIfDifferent tr H eqs ((a, b), k) =
      Option.mapPartial
        (fn f =>
          if Abt.eq (f a, f b) then NONE
          else SOME @@ makeEqTypeWith tr f H ((a, b), k))
        (restrict H eqs)

    fun makeTrue tr H eqs default a =
      case restrict H eqs of
        NONE => (NONE, default)
      | SOME f =>
          let
            val (goal, hole) = makeTrueWith tr f H a
          in
            (SOME goal, hole)
          end

    structure View =
    struct
      fun makeAsEqIfAllDifferent tr H eqs ((m, n), a) ns =
        Option.mapPartial
          (fn f =>
            if List.exists (fn n' => Abt.eq (f m, f n')) ns then NONE
            else SOME @@ View.makeAsEqWith tr f H ((m, n), a))
          (restrict H eqs)

      fun makeAsEqType tr H eqs ((a, b), l, k) =
        Option.mapPartial
          (fn f => SOME @@ View.makeAsEqTypeWith tr f H ((a, b), l, k))
          (restrict H eqs)

      fun makeAsEqTypeIfDifferent tr H eqs ((a, b), l, k) =
        Option.mapPartial
          (fn f =>
            if Abt.eq (f a, f b) then NONE
            else SOME @@ View.makeAsEqTypeWith tr f H ((a, b), l, k))
          (restrict H eqs)
    end
  end

  (* code shared by Com, HCom and FCom. *)
  structure ComKit =
  struct
    (* todo: optimizing the restriction process even further. *)
    (* todo: pre-restrict r=0, r=1, 0=r and 1=r. *)
    (* todo: try to reduce substitution. *)

    (* Produce the list of goals requiring that tube aspects agree with each other.
         forall i <= j.
           N_i = P_j in A [Psi, y | r_i = r_i', r_j = r_j']
     *)
    local
      (* These functions have ticks because their correctness depends on the code in
       * genInterTubeGoals. -favonia *)
      fun genTubeGoals' tr (H : Sequent.hyps) ((tubes0, tubes1), ty) =
        ListPairUtil.mapPartialEq
          (fn ((eq, t0), (_, t1)) => Restriction.makeEq tr H [eq] ((t0, t1), ty))
          (tubes0, tubes1)

      fun genInterTubeGoalsExceptDiag' tr (H : Sequent.hyps) ((tubes0, tubes1), ty) =
        ListPairUtil.enumPartialInterExceptDiag
          (fn ((eq0, t0), (eq1, t1)) => Restriction.makeEqIfDifferent tr H [eq0, eq1] ((t0, t1), ty))
          (tubes0, tubes1)
    in
      fun genInterTubeGoals tr (H : Sequent.hyps) w ((tubes0, tubes1), ty) =
        let
          val tubes0 = VarKit.alphaRenameTubes w tubes0
          val tubes1 = VarKit.alphaRenameTubes w tubes1

          val goalsOnDiag = genTubeGoals' tr (H @> (w, AJ.TERM O.DIM)) ((tubes0, tubes1), ty)
          val goalsNotOnDiag = genInterTubeGoalsExceptDiag' tr (H @> (w, AJ.TERM O.DIM)) ((tubes0, tubes1), ty)
        in
          goalsOnDiag @ goalsNotOnDiag
        end
    end

    (* Produce the list of goals requiring that tube aspects agree with the cap.
         forall i.
           M = N_i<r/y> in A [Psi | r_i = r_i']
     *)
    fun genCapTubeGoalsIfDifferent tr H ((cap, (r, tubes)), ty) =
      List.mapPartial
        (fn (eq, (u, tube)) =>
          Restriction.makeEqIfDifferent tr H [eq] ((cap, substVar (r, u) tube), ty))
        tubes

    (* Note that this does not check whether the 'ty' is a base type.
     * It's caller's responsibility to check whether the type 'ty'
     * recognizes FCOM as values. *)
    fun genEqFComGoals tr H w (args0, args1) ty =
      let
        val {dir=dir0, cap=cap0, tubes=tubes0 : abt Syn.tube list} = args0
        val {dir=dir1, cap=cap1, tubes=tubes1 : abt Syn.tube list} = args1
        val () = Assert.dirEq "genFComGoals" (dir0, dir1)
        val eqs0 = List.map #1 tubes0
        val eqs1 = List.map #1 tubes1
        val _ = Assert.equationsEq "genFComGoals equations" (eqs0, eqs1)
        val _ = Assert.tautologicalEquations "genFComGoals tautology checking" eqs0

        val goalCap = makeEq tr H ((cap0, cap1), ty)
      in
           goalCap
        :: genInterTubeGoals tr H w ((tubes0, tubes1), ty)
         @ genCapTubeGoalsIfDifferent tr H ((cap0, (#1 dir0, tubes0)), ty)
      end
  end

  structure HCom =
  struct
    fun Eq jdg =
      let
        val tr = ["HCom.Eq"]

        val H >> ajdg = jdg
        val ((lhs, rhs), ty) = View.matchAsEq ajdg
        val k = K.HCOM
        (* these operations could be expensive *)
        val Syn.HCOM {dir=dir0, ty=ty0, cap=cap0, tubes=tubes0} = Syn.out lhs
        val Syn.HCOM {dir=dir1, ty=ty1, cap=cap1, tubes=tubes1} = Syn.out rhs
        val () = Assert.dirEq "HCom.Eq direction" (dir0, dir1)

        (* equations *)
        val eqs0 = List.map #1 tubes0
        val eqs1 = List.map #1 tubes1
        val _ = Assert.equationsEq "HCom.Eq equations" (eqs0, eqs1)
        val _ = Assert.tautologicalEquations "HCom.Eq tautology checking" eqs0

        (* type *)
        val goalTy0 = makeEqType tr H ((ty0, ty1), k)
        val goalTy = View.makeAsSubTypeIfDifferent tr H (ty0, ty) (* (ty0, k) is proved *)

        (* cap *)
        val goalCap = makeEq tr H ((cap0, cap1), ty0)

        val w = Sym.new ()
      in
        |>: goalCap
         >:+ ComKit.genInterTubeGoals tr H w ((tubes0, tubes1), ty0)
         >:+ ComKit.genCapTubeGoalsIfDifferent tr H ((cap0, (#1 dir0, tubes0)), ty0)
         >: goalTy0 >:? goalTy
        #> (H, axiom)
      end

    fun EqCapL jdg =
      let
        val tr = ["HCom.EqCapL"]

        val H >> ajdg = jdg
        val ((hcom, other), ty) = View.matchAsEq ajdg
        val k = K.HCOM
        (* these operations could be expensive *)
        val Syn.HCOM {dir=(r, r'), ty=ty0, cap, tubes} = Syn.out hcom
        val () = Assert.alphaEq' "HCom.EqCapL source and target of direction" (r, r')

        (* equations *)
        val _ = Assert.tautologicalEquations "HCom.EqCapL tautology checking" (List.map #1 tubes)

        (* type *)
        val goalTy0 = makeType tr H (ty0, k)
        val goalTy = View.makeAsSubTypeIfDifferent tr H (ty0, ty) (* (ty0, k) is proved *)

        (* eq *)
        val goalEq = View.makeAsEq tr H ((cap, other), ty)

        val w = Sym.new ()
      in
        |>: goalEq
         >:+ ComKit.genInterTubeGoals tr H w ((tubes, tubes), ty0)
         >:+ ComKit.genCapTubeGoalsIfDifferent tr H ((cap, (r, tubes)), ty0)
         >: goalTy0 >:? goalTy
        #> (H, axiom)
      end

    (* Search for the first satisfied equation in an hcom. *)
    fun EqTubeL jdg =
      let
        val tr = ["HCom.EqTubeL"]

        val H >> ajdg = jdg
        val ((hcom, other), ty) = View.matchAsEq ajdg
        val k = K.HCOM
        (* these operations could be expensive *)
        val Syn.HCOM {dir=(r, r'), ty=ty0, cap, tubes} = Syn.out hcom

        (* equations. they must be tautological because one of them is true. *)
        val (_, (u, tube)) = Option.valOf (List.find (fn (eq, _) => Abt.eq eq) tubes)

        (* type *)
        val goalTy0 = makeType tr H (ty0, k)
        val goalTy = View.makeAsSubTypeIfDifferent tr H (ty0, ty) (* (ty0, k) is proved *)

        (* cap *)
        (* the cap-tube adjacency premise guarantees that [cap] is in [ty0],
         * and thus there is nothing to prove! Yay! *)

        (* eq *)
        (* the tube-tube adjacency premise guarantees that this particular tube
         * is unconditionally in [ty], and thus alpha-equivalence is sufficient. *)
        val goalEq = makeEqIfDifferent tr H ((substVar (r', u) tube, other), ty0)

        val w = Sym.new ()
      in
        |>:? goalEq
         >:+ ComKit.genInterTubeGoals tr H w ((tubes, tubes), ty0)
         >:+ ComKit.genCapTubeGoalsIfDifferent tr H ((cap, (r, tubes)), ty0)
         >: goalTy0 >:? goalTy
        #> (H, axiom)
      end
  end
end

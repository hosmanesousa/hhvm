module Report_comparator : Asserter.Comparator
  with type t = Informant_sig.report = struct
    open Informant_sig
    type t = Informant_sig.report
    let to_string v = match v with
      | Move_along ->
        "Move_along"
      | Kill_server ->
        "Kill_server"
      | Restart_server ->
        "Restart_server"

    let is_equal exp actual =
      exp = actual
end;;


module Report_asserter = Asserter.Make_asserter (Report_comparator);;


module Tools = struct
  let fake_repo = Path.make "/tmp/fake"
  let hg_rev_1 = "abc"
  let hg_rev_2 = "def"
  let hg_rev_3 = "ghi"
  let hg_rev_4 = "jkl"
  let svn_1 = "1"
  let svn_2 = "5"
  let svn_3 = "200" (** is a significant distance from the above. *)
  let svn_4 = "230"

  type state_transition =
    | State_leave
    | State_enter

  let set_hg_to_svn_map () =
    Hg.Mocking.closest_svn_ancestor_bind_value hg_rev_1
      @@ Future.of_value svn_1;
    Hg.Mocking.closest_svn_ancestor_bind_value hg_rev_2
      @@ Future.of_value svn_2;
    Hg.Mocking.closest_svn_ancestor_bind_value hg_rev_3
      @@ Future.of_value svn_3;
    Hg.Mocking.closest_svn_ancestor_bind_value hg_rev_4
      @@ Future.of_value svn_4

  let set_next_watchman_state_transition move hg_rev =
    let open Hh_json in
    let json = JSON_Object
      [("rev", JSON_String hg_rev)] in
    let move = match move with
    | State_leave ->
      Watchman.State_leave ("hg.update", (Some json))
    | State_enter ->
      Watchman.State_enter ("hg.update", (Some json))
    in
    Watchman.Mocking.get_changes_returns
      (Watchman.Watchman_pushed move)

  (** Test the given transition to an hg_rev and assert the expected report. *)
  let test_transition informant transition hg_rev server_status
    expected_report assert_msg =
      set_next_watchman_state_transition
        transition hg_rev;
      let report = HhMonitorInformant.report
        informant server_status in
      Report_asserter.assert_equals expected_report report
        assert_msg
end;;


(** When base revision has changed significantly, informant asks
 * for server restart. *)
let test_informant_restarts_significant_move () =
  Tools.set_hg_to_svn_map ();
  Watchman.Mocking.init_returns @@ Some "test_mock_basic";
  Hg.Mocking.current_working_copy_base_rev_returns
    (Future.of_value Tools.svn_1);
  Watchman.Mocking.get_changes_returns
    (Watchman.Watchman_pushed (Watchman.Files_changed SSet.empty));
  let informant = HhMonitorInformant.init {
    HhMonitorInformant.root = Tools.fake_repo;
    state_prefetcher = State_prefetcher.dummy;
    allow_subscriptions = true;
    use_dummy = false;
  } in
  let report = HhMonitorInformant.report
    informant Informant_sig.Server_alive in
  Report_asserter.assert_equals Informant_sig.Move_along report
    "no distance moved" ;

  (**** Following tests all have a State_enter followed by a State_leave *)

  (** Move base revisions insignificant distance away. *)
  Tools.test_transition
    informant Tools.State_enter Tools.hg_rev_2
    Informant_sig.Server_alive Informant_sig.Move_along
    "state enter insignificant distance";
  Tools.test_transition
    informant Tools.State_leave Tools.hg_rev_2
    Informant_sig.Server_alive Informant_sig.Move_along
    "state leave insignificant distance";

  (** Move significant distance. *)
  Tools.test_transition
    informant Tools.State_enter Tools.hg_rev_3
    Informant_sig.Server_alive Informant_sig.Kill_server
    "state enter significant distance";
  Tools.test_transition
    informant Tools.State_leave Tools.hg_rev_3
    Informant_sig.Server_dead Informant_sig.Restart_server
    "state leave significant distance";

  (** Informant now sitting at revision 200. Moving to 230 no restart. *)
  Tools.test_transition
    informant Tools.State_enter Tools.hg_rev_4
    Informant_sig.Server_alive Informant_sig.Move_along
    "state enter insignificant distance";
  Tools.test_transition
    informant Tools.State_leave Tools.hg_rev_4
    Informant_sig.Server_alive Informant_sig.Move_along
    "state leave insignificant distance";

  (** Moving back to 200 no restart. *)
  Tools.test_transition
    informant Tools.State_enter Tools.hg_rev_3
    Informant_sig.Server_alive Informant_sig.Move_along
    "state enter insignificant distance";
  Tools.test_transition
    informant Tools.State_leave Tools.hg_rev_3
    Informant_sig.Server_alive Informant_sig.Move_along
    "state leave insignificant distance";

  (** Moving back to SVN rev 5 (hg_rev_2) restarts. *)
  Tools.test_transition
    informant Tools.State_enter Tools.hg_rev_2
    Informant_sig.Server_alive Informant_sig.Kill_server
    "state enter significant distance";
  Tools.test_transition
    informant Tools.State_leave Tools.hg_rev_2
    Informant_sig.Server_dead Informant_sig.Restart_server
    "state leave significant distance";
  true

let tests =
  [
    "test_informant_restarts_significant_move",
      test_informant_restarts_significant_move;
  ]

let () =
  Unit_test.run_all tests

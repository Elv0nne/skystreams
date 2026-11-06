"""report.py's outage rule. From the repository: python3 -B -m unittest discover -s tool/qoe"""
import json, os, tempfile, unittest

import report


def row(**over):
    """A drop20-hls row that keeps every rule: the picture held through 7.2 s still, a reopen 1.4 s after the server."""
    r = {
        'scenario': 'drop20-hls', 'media': 'hls', 'outageMs': 20000, 'playingAtEnd': True, 'finalState': 'playing',
        'pictureMovingAtEnd': True, 'pictureFrozenMs': 7200, 'startupViews': 0, 'heldPictureSeen': True,
        'statusSeen': ['reconnecting'],
        'reopens': [{'afterCutMs': 21300, 'reason': 'retry', 'keptPicture': True}],
        'waits': [{'afterCutMs': 16200, 'label': 'reconnecting', 'ms': 5050}],
        'checks': [{'afterCutMs': 16100, 'sourceIndex': 0, 'kind': 'network', 'status': None},
                   {'afterCutMs': 21200, 'sourceIndex': 0, 'kind': 'answers', 'status': 206}],
        'failovers': [], 'gaveUp': None, 'signs': ['videoStarved'], 'reopenAfterServerMs': 1400, 'spotOffMs': -500,
    }
    r.update(over)
    return r


class OutageRule(unittest.TestCase):
    def test_a_recovery_that_keeps_every_rule_passes(self):
        self.assertIsNone(report.outage_rule(row()))
        self.assertEqual(report.outage(row()), 'PASS (still 7.2 s; reopened 1.4 s after the server)')

    def test_a_picture_frozen_under_running_audio_fails(self):
        # Part 2's macOS drop20-hls: the audio ran the clock to the end, the picture had stood still since cut + 15.6 s.
        r = row(pictureMovingAtEnd=False, pictureFrozenMs=59400, reopens=[], waits=[], checks=[], signs=[],
                statusSeen=[], heldPictureSeen=False, reopenAfterServerMs=None, spotOffMs=None)
        self.assertEqual(report.outage_rule(r), "the picture isn't moving at the end (playing)")
        self.assertTrue(report.outage(r).startswith('**FAIL**: '))

    def test_a_moving_picture_with_the_player_not_playing_fails(self):
        r = row(playingAtEnd=False, finalState='buffering')
        self.assertEqual(report.outage_rule(r), 'not playing at the end (buffering)')

    def test_a_row_with_no_decoder_counts_cannot_pass(self):
        self.assertEqual(report.outage_rule(row(pictureMovingAtEnd=None)),
                         "the picture wasn't measured: no decoder counts")

    def test_a_part_2_row_cannot_pass(self):
        # The fields Parts 1 and 2 reported, and nothing about the picture.
        old = {'scenario': 'drop20-hls', 'ttffMs': 1461, 'stalls': 1, 'stalledMs': 148, 'endedOrError': False,
               'startupViews': 0, 'playingAtEnd': True, 'finalState': 'playing', 'endPosMs': 83798}
        self.assertEqual(report.outage_rule(old), "the picture wasn't measured: no decoder counts")

    def test_giving_up_fails(self):
        self.assertEqual(report.outage_rule(row(gaveUp='sessionCap')), 'gave up (sessionCap)')

    def test_a_failover_from_the_only_source_fails(self):
        r = row(failovers=[{'afterCutMs': 30000, 'to': 1, 'reason': 'failover'}])
        self.assertEqual(report.outage_rule(r), 'failed over to source 1')

    def test_the_start_up_view_over_a_same_source_recovery_fails(self):
        self.assertEqual(report.outage_rule(row(startupViews=8)), 'the start-up view was up for 2.0 s')

    def test_a_reopen_that_dropped_the_picture_fails(self):
        r = row(reopens=[{'afterCutMs': 21300, 'reason': 'retry', 'keptPicture': False}])
        self.assertEqual(report.outage_rule(r), "a reopen didn't keep the picture")

    def test_a_reopen_the_output_never_held_fails(self):
        self.assertEqual(report.outage_rule(row(heldPictureSeen=False)), 'no reopen held the picture on screen')

    def test_a_wait_with_no_status_line_fails(self):
        self.assertEqual(report.outage_rule(row(statusSeen=[])),
                         "a wait with no 'Reconnecting…' or 'Waiting for network…' over the picture")
        # A reopen that needed no wait can be over between two looks at the screen.
        self.assertIsNone(report.outage_rule(row(statusSeen=[], waits=[])))

    def test_a_picture_still_longer_than_the_outage_and_4_s_fails(self):
        self.assertIsNone(report.outage_rule(row(pictureFrozenMs=24000)))
        self.assertEqual(report.outage_rule(row(pictureFrozenMs=24100)),
                         'the picture stood still 24.1 s, through a 20.0 s outage')

    def test_a_reopen_far_from_where_the_picture_stopped_fails(self):
        self.assertIsNone(report.outage_rule(row(spotOffMs=-6000)))
        self.assertEqual(report.outage_rule(row(spotOffMs=-7000)), 'reopened -7.0 s from where the picture stopped')
        mp4 = row(scenario='drop20-mp4', media='file', spotOffMs=2500)
        self.assertEqual(report.outage_rule(mp4), 'reopened 2.5 s from where the picture stopped')
        self.assertEqual(report.outage_rule(row(spotOffMs=None)), 'the reopen has no start to judge')

    def test_a_reopen_late_after_the_server_answered_fails(self):
        self.assertIsNone(report.outage_rule(row(reopenAfterServerMs=2500)))
        self.assertEqual(report.outage_rule(row(reopenAfterServerMs=3100)),
                         'reopened 3.1 s after the server answered, past 2.5 s')
        self.assertEqual(report.outage_rule(row(reopenAfterServerMs=None)),
                         'no request of the reopen reached the server after it answered')

    def test_a_stall_has_no_reopen_timing(self):
        # The stalled server answers throughout, so there is no moment it "answers again" to time a reopen from.
        ridden = row(scenario='stall20-hls', pictureFrozenMs=11000, reopens=[], waits=[], checks=[], signs=[],
                     statusSeen=[], heldPictureSeen=False, reopenAfterServerMs=None, spotOffMs=None)
        self.assertIsNone(report.outage_rule(ridden))
        self.assertEqual(report.outage(ridden), 'PASS (still 11.0 s)')
        reopened = row(scenario='stall20-hls', reopenAfterServerMs=None)
        self.assertIsNone(report.outage_rule(reopened))
        self.assertEqual(report.outage(reopened), 'PASS (still 7.2 s)')
        # A time the row doesn't judge isn't printed either.
        self.assertEqual(report.outage(row(scenario='stall20-hls', reopenAfterServerMs=600)), 'PASS (still 7.2 s)')


def two_source(**over):
    """A gone403-2src row that keeps every rule: A answered 403, and recovery failed over to B at once."""
    r = row(scenario='gone403-2src', outageMs=150000, pictureFrozenMs=9800, startupViews=6, heldPictureSeen=False,
            statusSeen=[], reopens=[], waits=[], signs=['videoStarved'],
            checks=[{'afterCutMs': 23000, 'sourceIndex': 0, 'kind': 'gone', 'status': 403}],
            failovers=[{'afterCutMs': 23100, 'to': 1, 'reason': 'failover'}],
            reopenAfterServerMs=None, spotOffMs=-800)
    r.update(over)
    return r


class NewRows(unittest.TestCase):
    def test_a_long_drop_waits_with_reconnecting_over_the_picture(self):
        r = row(scenario='drop60-hls', outageMs=60000, pictureFrozenMs=47000)
        self.assertIsNone(report.outage_rule(r))
        self.assertEqual(report.outage_rule(dict(r, waits=[])), 'no wait labelled reconnecting')
        self.assertEqual(report.outage_rule(dict(r, statusSeen=['waitingForNetwork'])),
                         "'Reconnecting…' never showed over the picture")

    def test_offline_waits_for_the_network_and_has_no_server_to_time_from(self):
        r = row(scenario='offline-120', outageMs=120000, pictureFrozenMs=104000, statusSeen=['waitingForNetwork'],
                waits=[{'afterCutMs': 24000, 'label': 'waitingForNetwork', 'ms': 99000}], reopenAfterServerMs=None)
        self.assertIsNone(report.outage_rule(r))
        self.assertEqual(report.outage_rule(dict(r, statusSeen=['reconnecting'])),
                         "'Waiting for network…' never showed over the picture")

    def test_a_gone_source_fails_over_at_once(self):
        self.assertIsNone(report.outage_rule(two_source()))
        self.assertEqual(report.outage(two_source()), 'PASS (still 9.8 s)')
        self.assertEqual(report.outage_rule(two_source(failovers=[])), 'expected one failover, to source 1, not []')
        late = two_source(failovers=[{'afterCutMs': 30100, 'to': 1, 'reason': 'failover'}])
        self.assertEqual(report.outage_rule(late), 'failed over 7.1 s after the first gone check, past 5.0 s')
        self.assertEqual(report.outage_rule(two_source(checks=[])), 'no check answered gone')

    def test_a_host_down_fails_over_after_30_s_of_no_answer(self):
        def down(at):
            return two_source(scenario='hostdown-2src', outageMs=120000, pictureFrozenMs=35000,
                              checks=[{'afterCutMs': 20000, 'sourceIndex': 0, 'kind': 'network', 'status': None},
                                      {'afterCutMs': 20050, 'sourceIndex': 1, 'kind': 'answers', 'status': 206}],
                              failovers=[{'afterCutMs': at, 'to': 1, 'reason': 'failover'}])
        self.assertIsNone(report.outage_rule(down(51000)))
        self.assertEqual(report.outage_rule(down(45000)),
                         'failed over 25.0 s after the first network check, before 28.0 s')
        self.assertEqual(report.outage_rule(down(65000)),
                         'failed over 45.0 s after the first network check, past 40.0 s')

    def test_busy_checks_wait_as_long_as_retry_after_asks(self):
        def busy(*at, after=4200):
            return row(scenario='busy503-ra', outageMs=29000, pictureFrozenMs=14000, waits=[],
                       checks=[{'afterCutMs': t, 'sourceIndex': 0, 'kind': 'busy', 'status': 503} for t in at],
                       reopenAfterServerMs=after)
        self.assertIsNone(report.outage_rule(busy(20000, 24100)))
        self.assertEqual(report.outage_rule(busy(20000, 22000)),
                         'busy checks only 2.0 s apart, sooner than Retry-After asked')
        self.assertEqual(report.outage_rule(busy(20000, 24100, after=7000)),
                         'reopened 7.0 s after the server answered, past 6.5 s')
        self.assertEqual(report.outage_rule(busy()), 'no check answered busy')

    def test_a_live_reopen_starts_at_the_edge_and_has_more_time(self):
        live = row(scenario='live-drop20', media='live', spotOffMs=None, reopenAfterServerMs=4000)
        self.assertIsNone(report.outage_rule(live))
        self.assertEqual(report.outage_rule(dict(live, reopenAfterServerMs=5000)),
                         'reopened 5.0 s after the server answered, past 4.5 s')

    def test_a_row_whose_request_log_went_unread_says_so(self):
        # Windows, P1 Part 3: the suite's read of the server's log timed out, and the row read as a reopen that never
        # reached the server.
        unread = row(reopenAfterServerMs=None, requestsRead=False)
        self.assertEqual(report.outage_rule(unread), "the server's request log could not be read: no reopen timing")

    def test_every_new_row_has_its_line_in_the_table(self):
        rows = {sc for _, sc, f in report.ROWS if f is report.outage}
        for name in ('drop60-mp4', 'drop60-hls', 'outage120-hls', 'offline-120', 'gone403-2src', 'busy503-ra',
                     'hostdown-2src', 'live-drop20'):
            self.assertIn(name, rows)
            self.assertIn(name, report.EXPECT)


class Table(unittest.TestCase):
    def test_a_row_the_suite_skipped_says_why(self):
        data = {'offline-120': {'scenario': 'offline-120', 'skipped': 'no Android device'}}
        self.assertEqual(report.cell(data, 'offline-120', report.outage), 'skipped: no Android device')

    def test_an_outage_line_loads_with_its_lists(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, 'run.log')
            with open(path, 'w') as f:
                f.write('00:12 +3: drop20-hls\nQOE ' + json.dumps(row()) + '\n')
            data = report.load(path)
        self.assertEqual(report.cell(data, 'drop20-hls', report.outage),
                         'PASS (still 7.2 s; reopened 1.4 s after the server)')



class EndedFilm(unittest.TestCase):
    def test_a_clean_end_keeps_the_card_and_reopens_nothing(self):
        self.assertEqual(report.ended_film({'endedCard': True, 'afterEnd': []}), 'card; nothing reopened')

    def test_an_end_read_as_a_failure_says_what_followed(self):
        self.assertEqual(report.ended_film({'endedCard': False, 'afterEnd': ['error', 'reopen']}),
                         'NO CARD; error, reopen')


class RealTorrent(unittest.TestCase):
    def test_a_real_torrent_reads_its_start_settings_and_peers(self):
        row = {
            'scenario': 'torrent-sintel', 'ttffMs': 14200,
            'torrent': {'settings': 'applied', 'setMs': 2310},
            'readBack': {'CacheSize': 268435456, 'ReaderReadAHead': 75},
            'peersAtFirstFrame': 18,
        }
        self.assertEqual(
            report.torrent(row),
            '14.2; applied 256 MB / 75 %; set 2.3 s; 18 peers')

    def test_a_torrent_whose_server_was_up_says_so(self):
        row = {'scenario': 'torrent-sintel-again', 'ttffMs': 9000,
               'torrent': {'settings': 'unchanged'},
               'readBack': {'CacheSize': 268435456, 'ReaderReadAHead': 75},
               'peersAtFirstFrame': 9}
        self.assertEqual(report.torrent(row),
                         '9.0; unchanged 256 MB / 75 %; 9 peers')


if __name__ == '__main__':
    unittest.main()

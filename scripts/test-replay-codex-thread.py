import importlib.util
from pathlib import Path
import unittest
spec = importlib.util.spec_from_file_location('replay', Path(__file__).with_name('replay-codex-thread.py'))
replay = importlib.util.module_from_spec(spec); spec.loader.exec_module(replay)

class ReplayTests(unittest.TestCase):
    def test_calls_keep_their_turn_when_output_arrives_later(self):
        def record(payload): return {'type':'response_item','timestamp':'2026-09-07T20:00:00Z','payload':payload}
        rows = [record({'type':'message','role':'user','content':[{'type':'input_text','text':'First'}]}),
                record({'type':'custom_tool_call','call_id':'a','name':'exec','input':'read'}),
                record({'type':'message','role':'user','content':[{'type':'input_text','text':'Second'}]}),
                record({'type':'custom_tool_call_output','call_id':'a','output':[{'type':'text','text':'result'}]}),
                record({'type':'reasoning','encrypted_content':'PRIVATE','summary':['PRIVATE']}),
                record({'type':'message','role':'assistant','channel':'commentary','content':[{'type':'output_text','text':'Checking'}]})]
        turns = replay.messages(rows)
        self.assertEqual(turns[0]['items'][0]['contentItems'][0]['text'],'result')
        self.assertEqual(turns[0]['items'][0]['status'],'completed')
        self.assertNotIn('PRIVATE',str(turns))
        self.assertEqual(turns[1]['items'][1]['phase'],'commentary')
    def test_missing_output_is_interrupted_not_a_live_operation(self):
        rows=[{'type':'response_item','timestamp':'2026-09-07T20:00:00Z','payload':p} for p in [
            {'type':'message','role':'user','content':[{'type':'input_text','text':'Go'}]},
            {'type':'function_call','call_id':'a','name':'tool','arguments':'{}'}]]
        self.assertEqual(replay.messages(rows)[0]['items'][0]['status'],'interrupted')

if __name__=='__main__': unittest.main()

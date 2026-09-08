"""Prevent an empty retry from being counted as successful production-log coverage."""
import io,json,unittest,urllib.error,urllib.parse
from pathlib import Path
from unittest.mock import patch
import observe

class QueryCoverageTests(unittest.TestCase):
 def setUp(self):
  self.start=observe.utc('2026-09-08T13:41:13.521061Z');self.end=observe.utc('2026-09-08T14:40:32.439317Z')
 def run_query(self,error=None):
  calls=[]
  class Opener:
   def open(inner,request,timeout):
    calls.append(urllib.parse.parse_qs(urllib.parse.urlparse(request.full_url).query))
    if error:raise error
    return io.BytesIO(json.dumps({'rows':[],'hasMoreRows':False}).encode())
  def fake_read(path,*args,**kwargs):
   if str(path).endswith('.vercel/project.json'):return json.dumps({'projectId':'test-project','orgId':'test-owner'})
   if str(path).endswith('com.vercel.cli/auth.json'):return json.dumps({'token':'test-only'})
   raise AssertionError('unexpected_file_read')
  with patch.object(Path,'read_text',fake_read),patch.object(observe.urllib.request,'build_opener',return_value=Opener()):
   result=observe.vercel(self.start,self.end,query_specs=[('4xx','voice-clone')])
  return result,calls
 def test_selected_query_is_really_requested(self):
  result,calls=self.run_query()
  self.assertEqual(len(calls),1);self.assertEqual(calls[0]['search'],['voice-clone']);self.assertEqual(calls[0]['statusCode'],['4xx'])
  self.assertTrue(result['completeReturnedPages']);self.assertEqual(len(result['queries']),1);self.assertEqual(result['queries'][0]['pages'],1)
 def test_collection_failure_remains_incomplete(self):
  result,calls=self.run_query(urllib.error.URLError('fixed test failure'))
  self.assertEqual(len(calls),1);self.assertFalse(result['completeReturnedPages']);self.assertEqual(result['queries'][0]['pages'],0);self.assertEqual(result['queries'][0]['issues'],['URLError'])
if __name__=='__main__':unittest.main()

"""Exercise the actual distributable via stdin/stdout. Fixtures are synthetic."""
import json
import os
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from build import ROOT, jdk

def request(d):
    dist = Path(os.environ.get("COURSE_ADAPTER_TEST_DIST", ROOT/"dist")).resolve()
    args = [str(jdk()/"java"),"-Xmx96m","-jar",str(dist/"engine.jar")]
    with tempfile.TemporaryDirectory() as work:
        p = subprocess.run(args,input=json.dumps(d,ensure_ascii=False),encoding="utf8",cwd=work,
                           capture_output=True,check=True,timeout=10)
        assert not list(Path(work).iterdir()),"Parser wrote to the working directory"
        assert not p.stderr,p.stderr
        return json.loads(p.stdout)

def parse(a,s):
    return request(dict(op="parse",adapter=a,source=s if isinstance(s,str) else json.dumps(s,ensure_ascii=False)))

class EngineTests(unittest.TestCase):
    def test_inventory_and_bytecode(self):
        inventory=request({"op":"list"})
        self.assertEqual(inventory['adapters'],json.loads((ROOT/'registry.json').read_text(encoding="utf8"))['adapters'])
        with zipfile.ZipFile(Path(os.environ.get('COURSE_ADAPTER_TEST_DIST',ROOT/'dist'))/'engine.jar') as j:
            classes={p[:-6].replace('/','.') for p in j.namelist() if p.endswith('.class')}
        rows=inventory['adapters']
        self.assertEqual(len(rows),84)
        self.assertEqual(len(set(r["className"] for r in rows)),83)
        self.assertTrue(all(r["className"] in classes for r in rows))
        self.assertEqual(set(r["inputKind"] for r in rows),{"html","json","csv"})
        self.assertTrue(any(r["id"]=="yzzy" and r["sourceFile"]=="YZZYParser.kt" for r in rows))

    def success(self,a,s,**fields):
        result=parse(a,s)
        self.assertTrue(result['ok'],(a,result))
        self.assertTrue(result['courses'])
        row=result['courses'][0]
        self.assertEqual({k:row.get(k) for k in fields},fields,a)
        return result

    def test_csv_utf8_and_quoted_field(self):
        self.success("CSVParser",'标题,星期,开始,结束,教师,地点,周次\n"数学,应用",2,3,4,林老师,甲101,2-16双',
                     name="数学,应用",day=2,teacher="林老师",room="甲101",startWeek=2,endWeek=16,type=2)
    def test_selected_html(self):
        html='<table id="table1"><tr><td class="festival">3</td><td id="2-3"><div><span class="title">离散数学</span><p><i title="教师">林老师</i></p><p><i title="上课地点">甲101</i></p><p><i title="节/周">(3-4节)1-15周(单)</i></p></div></td></tr></table>'
        self.success("zf_new",html,name="离散数学",day=2,startNode=3,endNode=4,startWeek=1,endWeek=15,type=1,room="甲101")
    def test_urp_weekday_spellings(self):
        head="<thead><tr>"+"".join(f"<th>{v}</th>" for v in ["课程名","教师","周次","星期","节次","节数","教学楼","教室"])+"</tr></thead>"
        labels=["一","星期二","周三","4","五","星期六","天","星期日"]
        body="".join("<tr>"+"".join(f"<td>{v}</td>" for v in ["线性代数","林老师","1-16周",d,"3-4","2","理教","101"])+"</tr>" for d in labels)
        r=self.success("urp_new",'<table class="table table-striped table-bordered">'+head+"<tbody>"+body+"</tbody></table>",name="线性代数",day=1,startNode=3,endNode=4)
        self.assertEqual([c["day"] for c in r["courses"]],[1,2,3,4,5,6,7,7])
    def test_ctgu_uses_html_not_file(self):
        fields=dict(kcmc='实验课',sjms='连续周 星期二 晚上第10节-晚上第11节',ksz='2-8',kcxf='2.5',rkjsxm='林老师',dz='实验室')
        source='<table><tbody><tr>'+''.join(f'<td field="{k}"><span>{v}</span></td>' for k,v in fields.items())+'</tr></tbody></table>'
        self.success("CTGUParser",source,day=2,startNode=10,endNode=11,credit=2.5,startTime='19:00',endTime='20:35')
        self.assertEqual(parse('ctgu','file:///unrelated.html')['code'],'UNSUPPORTED_INPUT')
    def test_buaa_json(self):
        c=dict(courseName="算法",dayOfWeek=3,placeName="A101",cellDetail=[{},{"text":"李老师[2-16周(双)]"}],
               titleDetail=['']*8+['讨论课'],beginSection=3,endSection=4,credit="3",beginTime="9:50",endTime="11:25")
        r=self.success('BUAAParser',{"datas":{"arrangedList":[c]}},name='算法',day=3,type=2,credit=3.0,note="讨论课",startTime='09:50')
        self.assertEqual(len(r['timeTable']['timeList']),14)
    def test_java_gdbh_no_cookie(self):
        r=self.success("GDBHParser",{"data":[dict(cname="网络实验",week=4,croomno="A103",name="周老师",seq=2,startweek=1,endweek=9,xf=1.5)]},
                       day=4,name="网络实验",startNode=3,endNode=4,credit=1.5)
        self.assertEqual(r['timeTable']['name'],"桂电北海")
    def test_replaced_online_acquisition(self):
        self.success('JXAUJkParser',{"Data":[dict(SkZhou="1-6,9",KcMc="测试",XingQi="3.0",Skdd="101",Rkls="教师",Jieci="1-2节")]},day=3,name="测试")
        self.success('SUSTechParser',[{"SKSJ":"科学[林][课程-甲班][1-8周][101][第1-2节]","KEY":"xq2_jc1"}],name="科学",day=2,room="101")
        self.success('YGUParser',{"code":0,"data":[{"weekList":[{"kcbVoList":[dict(jcs="1,2",zcs="1,3,5",dsz="单",jsmc="101",kcmc="编程",xq=1,rkls="林")]}]}]},
                     name="编程",day=1,type=1,endWeek=5)
        plan=dict(skbjmc="软件技术",kcmc="编程",skjsxm="林",zc=1,skrq="2025-09-02",jcshow="1-2",skcdmc="101",xq=1,xqs=2,xn="2025-2026")
        r=self.success('FSTVCParser',{"rows":[plan],"total":1},name="编程",day=2,endNode=2)
        self.assertEqual(r['startDate'],'2025-09-01')
        self.assertEqual(parse('FSTVCParser',{"rows":[plan],"total":3})["code"],"PARSE_ERROR")
    def test_composite_nwpu_and_single_sues(self):
        act=dict(courseName='数值分析',weekday=2,room='A室',teachers=['周老师'],startUnit=1,endUnit=2,
                 weekIndexes=[2,4],credits=2,lessonCode='AA01',campus='长安校区',lessonRemark=None,startTime="08:15",endTime="09:35")
        r=self.success('NWPUParser',dict(getData=dict(weekIndices=list(range(1,19)),lessons=[dict(semester={"startDate":"2026-09-07"})]),
                           printData=dict(studentTableVm={"activities":[act]}),semesterName="秋"),name='数值分析',startWeek=2,endWeek=2)
        self.assertEqual([c['startWeek'] for c in r['courses']],[2,4])
        self.assertEqual(r['maxWeek'],18)
        vm=dict(activities=[act],arrangedLessonSearchVms=[dict(semester=dict(startDate="2026-09-07"))],
                timeTableLayout=dict(name="示例作息",courseUnitList=[dict(indexNo=1,startTime=815,endTime=855)]))
        self.success('SUESParser2',dict(studentTableVms=[vm]),name='数值分析',startTime="08:15",day=2,type=2)
    def test_jxnu_uses_real_day_and_confirmed_term(self):
        s='<table id="_ctl1_NewKcb"><tr><td>星期一</td><td>星期二</td></tr><tr><td></td><td></td><td bgcolor="#66ffcc"><div align="center">\n离散数学<br>(101教室)<br>教师</div></td></tr></table>'
        self.assertEqual(parse('JXNUParser',s)["code"],"NEED_TERM_WEEKS")
        r=request(dict(op="parse",adapter="JXNUParser",source=s,termWeeks=12))
        self.assertTrue(r["ok"],r)
        row=r["courses"][0]
        self.assertEqual([row[k] for k in ("name","day","startNode","endNode","room","teacher","startWeek","endWeek")],["离散数学",1,1,2,"101教室","教师",1,12])
        self.assertEqual(parse("JXNUParser",s.replace('bgcolor="#66ffcc"',''))["code"],"NO_COURSES")
        for bad in (0,54,1.2,"16",True):
            self.assertEqual(request(dict(op="parse",adapter="JXNUParser",source=s,termWeeks=bad))["code"],"INVALID_REQUEST")
    def test_thu_explicit_and_relative_weeks(self):
        s='<script>\nsetInitValue()\nstrHTML += "<b>示例课</b>";\nstrHTML1 += "；WEEK";\ndocument.getElementById("a1_2");\nsetInitValue\n</script>'
        for label,expected in (('全周',(1,11,0)),('单周',(1,11,1)),('双周',(2,10,2)),('后八周',(4,11,0))):
            self.assertEqual(parse('THUParser',s.replace("WEEK",label))["code"],"NEED_TERM_WEEKS")
            r=request(dict(op="parse",adapter="THUParser",source=s.replace("WEEK",label),termWeeks=11))
            self.assertTrue(r["ok"],r)
            self.assertEqual(tuple(r['courses'][0][k] for k in ('startWeek','endWeek','type')),expected)
        self.success('THUParser',s.replace('WEEK','第2-5周'),day=2,startWeek=2,endWeek=5)
        self.assertEqual(parse('THUParser',s.replace("WEEK",""))['code'],"NO_COURSES")
    def test_jinzhi_no_fabricated_day_or_period(self):
        def course(day,nodes):
            return f'<div class="wut_table"><div class="mtt_arrange_item"><b class="mtt_item_kcmc">数学</b><i class="mtt_item_room">1-12周,{day},{nodes},A101</i></div></div>'
        for value,day in (('星期二',2),('周三',3),('六',6),('天',7),('4',4)):
            self.success("JinZhiParser",course(value,'3-4节'),day=day,startNode=3,endNode=4)
        self.success("JinZhiParser",course("星期二","未知节次"),day=2,startNode=0,endNode=0)
        self.success("JinZhiParser",course("未知星期","1-2节"),day=0,startNode=0,endNode=0)

    def test_bad_frames_and_request_privacy(self):
        r=parse('nwpu','<html>password=TEST_ONLY</html>')
        self.assertEqual(r['code'],'UNSUPPORTED_INPUT')
        for req,code in ((dict(op="lookup"),"INVALID_REQUEST"),(dict(op="parse",adapter="java.lang.Runtime",source="{}"),"UNKNOWN_ADAPTER"),
                         (dict(op="parse",adapter="zf_new",source="<html>TEST_ONLY</html>"),"PARSE_ERROR"),
                         (dict(op="parse",adapter="csv",source=""),"NO_COURSES")):
            r=request(req)
            self.assertEqual(r['code'],code)
            self.assertNotIn('TEST_ONLY',json.dumps(r))
if __name__=="__main__":
    unittest.main(verbosity=2)


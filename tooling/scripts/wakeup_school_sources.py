"""Names come from parser sources, tests and change descriptions at CourseAdapter 0cb2904.
Entries below are the teaching sites named by those adapters (not credential endpoints).
A parser variant for graduates must not be selected by matching an undergraduate school prefix.
"""
SPECIAL = {
    "安徽师范大学":"NewAHNUParser AHNUParser", "安徽科技学院":"AHSTUParser",
    "北京电影学院（研究生）":"BFAforYJSParser", "北京交通大学":"BJTUParser",
    "北京师范大学珠海分校":"BNUZParser", "北京航空航天大学":"BUAAParser",
    "重庆对外经贸学院":"CCIBEParser", "长沙学院":"CSXYParser", "长春师范大学":"CNUParser",
    "重庆邮电大学":"CQUPTParser", "三峡大学（研究生）":"CTGUParser",
    "华东交通大学":"ECJTUParser", "华东师范大学":"ECNUParser", "华东政法大学":"ECUPLParser",
    "佛山职业技术学院":"FSPTParser", "福州软件职业技术学院":"FSTVCParser",
    "桂林电子科技大学（北海校区）":"GDBHParser", "广东白云学院":"GDBYXYParser",
    "广东第二师范学院":"GDEIParser", "广西工业职业技术学院":"WakeupParser",
    "广州大学（研究生）":"GZHUYJSParser", "合肥工业大学":"HFUTParser",
    "河海大学":"HHUParser", "黑龙江大学":"HLJUParser", "湖南信息职业技术学院":"HNIUParser",
    "河南经贸职业学院":"HNJMParser", "湖南科技大学":"HNUSTParser",
    "湖南科技大学潇湘学院":"HNUSTParser", "河南职业技术学院":"HNZJParser",
    "哈尔滨工程大学（研究生）":"HrbeuGraduateParser", "湖北汽车工业学院":"HUATParser",
    "湖南师范大学":"HUNNUParser", "华中科技大学":"HUSTParser", "江西航空职业技术学院":"JAVTCParser",
    "吉林大学（研究生）":"JLUParser", "暨南大学":"JNUParser", "江西农业大学":"JXAUJkParser JXAUParser",
    "江西师范大学":"JXNUParser", "辽宁轨道交通职业学院":"LNGDParser",
    "广州南方学院":"NFUParser", "南京大学":"NJUParser", "西北工业大学":"NWPUParser",
    "西北工业大学（研究生）":"NWPUGraduateParser", "南阳理工学院":"NYISTParser",
    "北京大学":"PekingParser", "中国人民大学":"RUCParser", "山东体育学院":"SDPEIParser",
    "上海科技大学（研究生）":"SHTechParser2024 SHTechParser", "上海大学":"SHUParser2024",
    "上海市高级技工学校":"SIMCParser", "上海工程技术大学高等职业技术学院":"SIMCParser",
    "上海应用技术大学":"SITParser", "上海工程技术大学":"SUESParser SUESParser2",
    "南方科技大学":"SUSTechParser", "西南交通大学（研究生）":"SWJTUGraduateParser",
    "中山大学":"SYSUParser2024 SYSUParser", "清华大学":"THUParser",
    "中国科学技术大学（研究生）":"USTCGraduateParser", "武汉船舶职业技术学院":"WISTParser",
    "西安建筑科技大学（研究生）":"XAUATParser", "西安交通大学（研究生）":"XJTUGraduateParser",
    "阳光学院":"YGUParser", "永州职业技术学院":"YZZYParser", "浙江交通职业技术学院":"ZjvtitParser",
    "浙江邮电职业技术学院":"ZPTCParser", "华南农业大学":"Qz2017Parser",
    **dict.fromkeys("西安工业大学 西北政法大学 大连海事大学 天津农学院 辽宁工程技术大学 重庆医科大学 山东商业职业技术学院".split(),"SupwisdomParser"),
}
ENTRIES = {
    "北京航空航天大学":"https://byxt.buaa.edu.cn/",
    "湖南师范大学":"https://jwglnew.hunnu.edu.cn/", "河海大学":"https://jwxt.hhu.edu.cn/jsxsd/",
    "南京大学":"https://ehallapp.nju.edu.cn/jwapp/sys/wdkb/*default/index.do",
    "南方科技大学":"https://tis.sustech.edu.cn/", "福州软件职业技术学院":"https://jw.fzrjxy.com/",
    "华中科技大学":"https://mhub.hust.edu.cn/kbPageController/by-course",
    "上海大学（选课系统）":"https://jwxk.shu.edu.cn/", "西北工业大学":"https://jwxt.nwpu.edu.cn/",
    "西北工业大学（研究生）":"https://yjsjy.nwpu.edu.cn/pyxx/home/index",
    "上海科技大学（研究生）":"https://graduate.shanghaitech.edu.cn/gsapp/sys/wdkbappshtech/*default/index.do",
    "中国科学技术大学（研究生）":"https://yjs1.ustc.edu.cn/",
    "西安建筑科技大学（研究生）":"https://gmis.xauat.edu.cn/pyxx",
    "西南交通大学（研究生）":"https://one.swjtu.edu.cn/new/swjtu/indexswjtu.html",
    "山东体育学院":"https://jw.sdpei.edu.cn/", "上海工程技术大学":"https://jxfw.sues.edu.cn/",
    "阳光学院":"https://ygu.edu.cn/user/login", "南阳理工学院":"https://app3.nyist.edu.cn/ui/",
    "重庆对外经贸学院":"https://my.vpn.ccibe.edu.cn/",
}
EXTRA_READ = {
    "上海大学": ["https://jwxk.shu.edu.cn","https://jwxt.shu.edu.cn"],
    "上海科技大学（研究生）": ["https://grad.shanghaitech.edu.cn","https://graduate.shanghaitech.edu.cn"],
    "西北工业大学（研究生）":["https://yjsjy.nwpu.edu.cn"],
}
CAMPUS_DOMAINS = {"jw.fzrjxy.com":"fzrjxy.com"}
SPECIAL["上海大学（选课系统）"]="SHUParser2024"

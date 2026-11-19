import 'print_data_school_site.dart';

// Each profile selects the *current user's* print view after school login.
// Parameters and paths are campus-specific; no student ID is supplied.
const additionalPrintDataSites = <PrintDataSchoolSite>[
  PrintDataSchoolSite(
    name: '郑州大学',
    origin: 'https://jwxt.zzu.edu.cn',
    numericTermLabel: true,
    tableShapes: [
      PrintDataTableShape.studentTableVms,
      PrintDataTableShape.studentTableVm,
      PrintDataTableShape.activities,
    ],
    query: {'semesterId': '{semesterId}', 'hasExperiment': 'true'},
  ),
  PrintDataSchoolSite(
    name: '中国石油大学（北京）克拉玛依校区',
    origin: 'https://eams.cupk.edu.cn',
    numericTermLabel: true,
    semesterSelector: 'select#semesters,select#allSemesters',
    readCourseClock: true,
  ),
  PrintDataSchoolSite(
    name: '中国石油大学（北京）本科',
    origin: 'https://bk.cup.edu.cn',
    numericTermLabel: true,
    semesterSelector: 'select#semesters,select#allSemesters',
    readCourseClock: true,
  ),
  PrintDataSchoolSite(
    name: '安徽大学',
    origin: 'https://jw.ahu.edu.cn',
    query: {'semesterId': '{semesterId}', 'hasExperiment': 'false'},
    readCourseClock: true,
  ),
];

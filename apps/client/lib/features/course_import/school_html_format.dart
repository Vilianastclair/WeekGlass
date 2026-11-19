/// Historical personal-timetable pages, separate from online school adapters.
enum SchoolHtmlFormat {
  peking('pku_html', '北京大学', '选课网个人课表列表'),
  hust('hust_html', '华中科技大学', '微校园课表列表'),
  sysu('sysu_html', '中山大学', '学生课表网格'),
  westlake('westlake_sis', '西湖大学', 'SIS 个人课表文件');

  const SchoolHtmlFormat(this.sourceId, this.school, this.page);

  final String sourceId;
  final String school;
  final String page;
}

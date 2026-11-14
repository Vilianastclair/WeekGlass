enum BatchEditField {
  title('名称'),
  color('颜色'),
  start('开始时间'),
  end('结束时间'),
  notes('备注');

  const BatchEditField(this.label);
  final String label;
}

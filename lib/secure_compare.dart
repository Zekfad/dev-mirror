bool secureCompare(String a, String b) {
  if(a.codeUnits.length != b.codeUnits.length)
    return false;

  var r = 0;
  for(var i = 0; i < a.codeUnits.length; i++) {
    r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return r == 0;
}

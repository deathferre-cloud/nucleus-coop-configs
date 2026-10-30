// SPDX-License-Identifier: GPL-3.0-or-later
// Compile with installed Jint/Newtonsoft, place EXE in an isolated fixture root,
// copy the built helper to fixture/setup/VRisingSettings.dll, then pass library root and patched handler.
using System;
using System.IO;
using System.Reflection;
using Newtonsoft.Json.Linq;
using Jint;
class VerifyVRisingSettings {
 static string libraries;
 static int Main(string[] args) {
  if(args.Length!=2){Console.WriteLine("Arguments: Nucleus library directory, patched V Rising handler file");return 2;}
  libraries=Path.GetFullPath(args[0]);
  AppDomain.CurrentDomain.AssemblyResolve+=(s,e)=>{string p=Path.Combine(libraries,new AssemblyName(e.Name).Name+".dll");return File.Exists(p)?Assembly.LoadFrom(p):null;};
  try{return Run(args[1]);}catch(Exception e){Console.WriteLine(e);return 1;}
 }
 static int Run(string handlerPath) {
  string fixture=AppDomain.CurrentDomain.BaseDirectory;
  string originalRoot=Path.Combine(fixture,"fixture-original");
  string source=Path.Combine(originalRoot,"AppData","LocalLow","Stunlock Studios","VRising","Settings","v4","ClientSettings.json");
  Directory.CreateDirectory(Path.GetDirectoryName(source));
  const string input="{\"Interface\":{\"ActionWheelShapeshiftAbility\":[],\"ActionWheelEmoteAbility\":[]},\"Sound\":{\"MasterVolume\":0.51,\"Driver\":\"test-driver\"},\"GraphicSettings\":{\"Brightness\":1.9},\"Controls\":{\"Preferences\":{}},\"Unknown\":{\"Items\":[1,\"x\",{}]}}";
  File.WriteAllText(source,input);
  var engine=new Engine(c=>c.AllowClr());
  engine.SetValue("sourceRoot",originalRoot);
  string handler=File.ReadAllText(handlerPath);
  int start=handler.IndexOf("  // Newtonsoft preserves");
  int end=handler.IndexOf("  ///////////// Registry edit",start);
  if(start<0||end<0)throw new Exception("Settings preparation block missing");
  string block=handler.Substring(start,end-start);
  for(int player=0;player<2;player++) {
   engine.Execute("var Context={PlayerID:"+player+",NucleusUserRoot:sourceRoot,Width:1920,Height:1080,StartArguments:' -screen-fullscreen 0'};");
   engine.Execute(block);
   string target=Path.Combine(fixture,"saves","V Rising","Player"+(player+1),"Settings","v4","ClientSettings.json");
   var saved=JObject.Parse(File.ReadAllText(target));
   saved["Sound"]["Driver"]="player-"+player;
   File.WriteAllText(target,saved.ToString());
   engine.Execute("Context.Width=1440; Context.Height=810;");engine.Execute(block);
   var result=JObject.Parse(File.ReadAllText(target));
   if(result["Interface"]["ActionWheelEmoteAbility"].Type!=JTokenType.Array||result["Interface"]["ActionWheelShapeshiftAbility"].Type!=JTokenType.Array)throw new Exception("Empty arrays lost");
   if(result["Controls"]["Preferences"].Type!=JTokenType.Object||!JToken.DeepEquals(result["Unknown"],JObject.Parse(input)["Unknown"]))throw new Exception("Unrelated data lost");
   if((string)result["Interface"]["Language"]!="russian"||(int)result["GraphicSettings"]["WindowMode"]!=3||(int)result["GraphicSettings"]["Resolution"]["x"]!=1440)throw new Exception("Wrong per-player settings");
   if((string)result["Sound"]["Driver"]!="player-"+player||(decimal)result["Sound"]["MasterVolume"]!=0.51m)throw new Exception("Per-player sound lost on repeat");
   string arguments=engine.GetValue("Context").AsObject().Get("StartArguments").AsString();
   if(!arguments.Contains("-persistentDataPath")||!arguments.Contains("Player"+(player+1))||!arguments.Contains("-logFile"))throw new Exception("Missing isolated launch arguments");
  }
  if(File.ReadAllText(source)!=input)throw new Exception("Original was changed");
  engine.SetValue("sourceSettingsRoot",Path.Combine(originalRoot,"AppData","LocalLow","Stunlock Studios","VRising"));engine.SetValue("sourceFile",source);
  bool refused=false;
  try{engine.Execute("vrSettings.Prepare(sourceSettingsRoot,sourceFile,1920,1080);");}catch{refused=true;}
  if(!refused||File.ReadAllText(source)!=input)throw new Exception("Original-write guard failed");
  Console.WriteLine("PASS: full unmodified settings block in real Jint, portable BaseDirectory, two players, arrays/objects/unknown keys preserved, per-player audio survives repeat, original unchanged and protected.");return 0;
 }
}

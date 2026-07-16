const __name=(value,name)=>value;
const a=(value)=>value;
__name(a,"updateUserConfig");
const paths=["config.json","settings.json","settings.local.json","mcp.json","mcp-tokens.json","trusted-hooks.json"];
const configShape={provider:null,model:null,reasoningEffort:null,theme:null,compactMode:null,telemetry:null,tasteLearning:null,featureModels:null,autoInstallExtension:null,forceOAuth:null,installed:null,firstMessageSent:null};
a({provider:"command-code"});
const permissionProbe=(settings)=>settings.permissions.autoApprove.create||settings.permissions.autoApprove.update||settings.permissions.autoApprove.delete;
const themes=new Set(["dark","light"]);
const transports=["stdio","http"];
const HookEvent=(event=>(event.PreToolUse="PreToolUse",event.PostToolUse="PostToolUse",event.Stop="Stop",event.SessionStart="SessionStart",event))(HookEvent||{});
const models={
  one:{id:"model-1",inputModalities:["text"],provider:"command-code",label:"Model 1",name:"Model 1",reasoningEfforts:["low","high"],contextWindow:1000},
  two:{id:"model-2",inputModalities:["text"],provider:"command-code",label:"Model 2",name:"Model 2",reasoningEfforts:["medium","high"],contextWindow:2000},
  three:{id:"model-3",inputModalities:["text","image"],provider:"command-code",label:"Model 3",name:"Model 3",contextWindow:3000},
  four:{id:"model-4",inputModalities:["text"],provider:"command-code",label:"Model 4",name:"Model 4",contextWindow:4000},
  five:{id:"model-5",inputModalities:["text"],provider:"command-code",label:"Model 5",name:"Model 5",contextWindow:5000}
};
const providers={"command-code":{id:"command-code",label:"Command Code",supportedModelProviders:["command-code"],requiresAuth:false}};
const featureModels=[
  {key:"titleGeneration",label:"Session titles",description:"Titles",defaultLabel:"Model 1"},
  {key:"compaction",label:"Compaction",description:"Compaction",defaultLabel:"Model 2"},
  {key:"toolDescription",label:"Tools",description:"Tools",defaultLabel:"Model 1"},
  {key:"tasteLearning",label:"Taste",description:"Taste"},
  {key:"tasteOnboarding",label:"Taste onboarding",description:"Taste onboarding",defaultLabel:"Model 3"}
];
void paths;void configShape;void permissionProbe;void themes;void transports;void HookEvent;void models;void providers;void featureModels;

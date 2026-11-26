import Foundation
import Testing
@testable import LampBibleMac
@testable import LampBibleMacSupport

/// A Codex writing turn over `codex app-server` (`decisions/0028`), pinned by
/// a turn recorded from Codex 0.170 and played by a fake Codex.
struct AgentCodexRunTests {
    /// One real turn, 2026-11-26, trimmed to what Lamp reads: Codex asked to
    /// run Blender outside its sandbox for the GPU, was declined, and said
    /// so. The workspace's path is replaced; nothing else is changed.
    static let recorded = #"""
{"id":2,"result":{"thread":{"id":"01a21a37-78fb-7381-8c61-b03daea883b1"}}}
{"method":"thread/started","params":{"thread":{"id":"01a21a37-78fb-7381-8c61-b03daea883b1"}}}
{"method":"turn/started","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turn":{"id":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34"}}}
{"method":"item/started","params":{"item":{"type":"agentMessage","id":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","text":"","phase":"commentary"},"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34"}}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":"I"},"emittedAtMs":1795736176697}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":"’ll"},"emittedAtMs":1795736176697}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":" check"},"emittedAtMs":1795736176697}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":" the"},"emittedAtMs":1795736176819}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":" folder"},"emittedAtMs":1795736176819}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":" instructions"},"emittedAtMs":1795736176965}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":","},"emittedAtMs":1795736176965}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":" then"},"emittedAtMs":1795736176965}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":" request"},"emittedAtMs":1795736176965}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":" permission"},"emittedAtMs":1795736176965}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":" to"},"emittedAtMs":1795736176965}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":" run"},"emittedAtMs":1795736176967}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":" Blender"},"emittedAtMs":1795736176967}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":" outside"},"emittedAtMs":1795736177083}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":" the"},"emittedAtMs":1795736177083}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":" sandbox"},"emittedAtMs":1795736177083}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":" because"},"emittedAtMs":1795736177083}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":" Ee"},"emittedAtMs":1795736177113}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":"vee"},"emittedAtMs":1795736177113}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":" needs"},"emittedAtMs":1795736177113}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":" Metal"},"emittedAtMs":1795736177115}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":" GPU"},"emittedAtMs":1795736177115}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":" access"},"emittedAtMs":1795736177115}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","delta":"."},"emittedAtMs":1795736177115}
{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_000dcbbf0697f8af016b08c2708bfc87d2b2551f9bcb998c8c","text":"I’ll check the folder instructions, then request permission to run Blender outside the sandbox because Eevee needs Metal GPU access.","phase":"commentary"},"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34"}}
{"method":"item/started","params":{"item":{"type":"reasoning","id":"rs_000dcbbf0697f8af016b08c276f92c87d2945b4619d46c1c0b","summary":[]},"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34"}}
{"method":"item/completed","params":{"item":{"type":"reasoning","id":"rs_000dcbbf0697f8af016b08c276f92c87d2945b4619d46c1c0b","summary":[]},"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34"}}
{"method":"item/started","params":{"item":{"type":"commandExecution","id":"exec-df7f2f66-ce26-4e49-9178-2e0ad3089ad5","command":"/bin/zsh -lc '/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup -E BLENDER_EEVEE --python-expr \"import bpy; s=bpy.context.scene; s.render.resolution_x=64; s.render.resolution_y=36\" -o //frame -F PNG -f 1'","cwd":"/Users/Reader/Library/Application Support/Lamp Bible/Library/AgentWorkspaces/Writing/talk","status":"inProgress","commandActions":[{"type":"unknown","command":"/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup -E BLENDER_EEVEE --python-expr \"import bpy; s=bpy.context.scene; s.render.resolution_x=64; s.render.resolution_y=36\" -o //frame -F PNG -f 1"}]},"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34"}}
{"method":"item/commandExecution/requestApproval","id":0,"params":{"kind":"command","threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"exec-df7f2f66-ce26-4e49-9178-2e0ad3089ad5","startedAtMs":1795736184767,"environmentId":"local","reason":"Allow Blender to run outside the sandbox so Eevee can access the Metal GPU and render frame 1?","command":"/bin/zsh -lc '/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup -E BLENDER_EEVEE --python-expr \"import bpy; s=bpy.context.scene; s.render.resolution_x=64; s.render.resolution_y=36\" -o //frame -F PNG -f 1'","cwd":"/Users/Reader/Library/Application Support/Lamp Bible/Library/AgentWorkspaces/Writing/talk","commandActions":[{"type":"unknown","command":"/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup -E BLENDER_EEVEE --python-expr \"import bpy; s=bpy.context.scene; s.render.resolution_x=64; s.render.resolution_y=36\" -o //frame -F PNG -f 1"}],"proposedExecpolicyAmendment":["/Applications/Blender.app/Contents/MacOS/Blender","-b","--factory-startup","-E","BLENDER_EEVEE","--python-expr","import bpy; s=bpy.context.scene; s.render.resolution_x=64; s.render.resolution_y=36","-o","//frame","-F","PNG","-f","1"],"availableDecisions":["accept",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["/Applications/Blender.app/Contents/MacOS/Blender","-b","--factory-startup","-E","BLENDER_EEVEE","--python-expr","import bpy; s=bpy.context.scene; s.render.resolution_x=64; s.render.resolution_y=36","-o","//frame","-F","PNG","-f","1"]}},"cancel"]}}
{"method":"serverRequest/resolved","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","requestId":0},"emittedAtMs":1795736184768}
{"method":"item/completed","params":{"item":{"type":"commandExecution","id":"exec-df7f2f66-ce26-4e49-9178-2e0ad3089ad5","command":"/bin/zsh -lc '/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup -E BLENDER_EEVEE --python-expr \"import bpy; s=bpy.context.scene; s.render.resolution_x=64; s.render.resolution_y=36\" -o //frame -F PNG -f 1'","cwd":"/Users/Reader/Library/Application Support/Lamp Bible/Library/AgentWorkspaces/Writing/talk","status":"declined","commandActions":[{"type":"unknown","command":"/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup -E BLENDER_EEVEE --python-expr \"import bpy; s=bpy.context.scene; s.render.resolution_x=64; s.render.resolution_y=36\" -o //frame -F PNG -f 1"}]},"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34"}}
{"method":"item/started","params":{"item":{"type":"agentMessage","id":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","text":"","phase":"final_answer"},"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34"}}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":"Permission"},"emittedAtMs":1795736186031}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":" to"},"emittedAtMs":1795736186031}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":" run"},"emittedAtMs":1795736186031}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":" Blender"},"emittedAtMs":1795736186031}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":" outside"},"emittedAtMs":1795736186031}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":" the"},"emittedAtMs":1795736186031}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":" sandbox"},"emittedAtMs":1795736186031}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":" was"},"emittedAtMs":1795736186031}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":" declined"},"emittedAtMs":1795736186031}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":"."},"emittedAtMs":1795736186031}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":" I"},"emittedAtMs":1795736186031}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":" stopped"},"emittedAtMs":1795736186032}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":" without"},"emittedAtMs":1795736186032}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":" retry"},"emittedAtMs":1795736186032}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":"ing"},"emittedAtMs":1795736186181}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":";"},"emittedAtMs":1795736186181}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":" no"},"emittedAtMs":1795736186181}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":" render"},"emittedAtMs":1795736186183}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":" was"},"emittedAtMs":1795736186183}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":" created"},"emittedAtMs":1795736186183}
{"method":"item/agentMessage/delta","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","itemId":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","delta":"."},"emittedAtMs":1795736186183}
{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_000dcbbf0697f8af016b08c279f94c87d2a9e18b3323dd35aa","text":"Permission to run Blender outside the sandbox was declined. I stopped without retrying; no render was created.","phase":"final_answer"},"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turnId":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34"}}
{"method":"turn/completed","params":{"threadId":"01a21a37-78fb-7381-8c61-b03daea883b1","turn":{"id":"01a21a37-7cc8-7de1-a1b2-b7f13f82cd34","status":"completed","error":null}}}
"""#

    private func summary(of lines: String) -> AgentChatRunSummary {
        var commentary = AgentCodexRun.Commentary()
        let kept = lines.split(separator: "\n").filter { line in
            guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return true }
            return !commentary.isCommentary(message)
        }
        return AgentChatRunSummary.summarize(output: kept.joined(separator: "\n"), provider: .codex)
    }

    @Test func theRecordedTurnReadsAsItsThreadAndItsAnswerWithoutTheCommentary() {
        let read = summary(of: Self.recorded)
        #expect(read.sessionID == "01a21a37-78fb-7381-8c61-b03daea883b1")
        #expect(read.response == "Permission to run Blender outside the sandbox was declined. I stopped without retrying; no render was created.")
        #expect(read.failure == nil)

        // What streams while it runs: the answer's words, never the
        // commentary's, and the command as a step.
        var commentary = AgentCodexRun.Commentary()
        var streamed = ""
        var steps: [AgentChatActivity] = []
        for line in Self.recorded.split(separator: "\n") {
            let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            if let message, commentary.isCommentary(message) { continue }
            for event in AgentChatWireParser.parse(String(line), provider: .codex) {
                if case .textFragment(let text) = event { streamed += text }
                if case .activity(let step) = event { steps.append(step) }
            }
        }
        #expect(streamed.hasPrefix("Permission to run Blender"))
        #expect(!streamed.contains("folder instructions"))
        #expect(steps.contains { if case .tool(name: "Command", let summary) = $0 { return summary?.hasPrefix("/Applications/Blender.app") == true }; return false })
    }

    @Test func theRecordedRequestComesToThePersonWithItsCommandFolderAndReason() throws {
        let line = try #require(Self.recorded.split(separator: "\n").first { $0.contains("requestApproval") })
        let message = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let key = try #require(AgentCodexRun.requestKey(message["id"] as Any))
        #expect(key == "codex-0")
        guard case .ask(let request) = AgentCodexRun.reply(
            to: message["method"] as! String, params: message["params"] as! [String: Any], id: key
        ) else { Issue.record("not put to the person"); return }
        #expect(request.alwaysAllowRule == nil)
        let shown = AgentToolApprovalSummary.of(request)
        #expect(shown.title == "Run a command outside its sandbox")
        let detail = try #require(shown.detail)
        // The command as it runs, without the shell Codex wraps it in.
        #expect(detail.hasPrefix("/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup -E BLENDER_EEVEE"))
        #expect(!detail.contains("zsh -lc"))
        #expect(detail.contains("In /Users/Reader/Library/Application Support/Lamp Bible/Library/AgentWorkspaces/Writing/talk"))
        #expect(detail.contains("Codex says: Allow Blender to run outside the sandbox so Eevee can access the Metal GPU"))
        #expect(shown.note?.contains("anything your account can") == true)
    }

    @Test func onlyAPlainCommandIsAskedAboutAndAllElseIsTurnedDown() {
        func reply(_ method: String, _ params: [String: Any]) -> AgentCodexRun.Reply {
            AgentCodexRun.reply(to: method, params: params, id: "codex-1")
        }
        func answer(_ reply: AgentCodexRun.Reply) -> NSDictionary? {
            if case .answer(let result) = reply { return result as NSDictionary }
            return nil
        }
        let command = "item/commandExecution/requestApproval"
        let declined: NSDictionary = ["decision": "decline"]
        #expect(answer(reply(command, ["command": "curl x", "networkApprovalContext": ["host": "x", "protocol": "https"]])) == declined)
        #expect(answer(reply(command, ["kind": "writeStdin", "command": "y"])) == declined)
        #expect(answer(reply(command, ["kind": "command"])) == declined)
        #expect(answer(reply(command, ["command": ""])) == declined)
        if case .ask = reply(command, ["command": "blender -b", "networkApprovalContext": NSNull()]) {} else { Issue.record("a null network context is none") }
        #expect(answer(reply("item/fileChange/requestApproval", ["grantRoot": "/"])) == declined)
        #expect(answer(reply("item/permissions/requestApproval", [:])) == ["permissions": [String: Any](), "scope": "turn"])
        #expect(answer(reply("item/tool/requestUserInput", [:])) == ["answers": [String: Any]()])
        #expect(answer(reply("mcpServer/elicitation/request", [:])) == ["action": "decline"])
        #expect(answer(reply("execCommandApproval", [:])) == ["decision": "denied"])
        #expect(answer(reply("applyPatchApproval", [:])) == ["decision": "denied"])
        if case .refuse(let reason) = reply("item/tool/call", [:]) { #expect(reason.contains("item/tool/call")) } else { Issue.record("not refused") }
    }

    /// A command's output, streamed for as long as it runs, is dropped; what
    /// the turn is made of is not.
    @Test func streamedOutputIsDroppedAndTheTurnIsKept() {
        func unread(_ line: String) -> Bool {
            AgentCodexRun.isUnread(try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any])
        }
        #expect(unread(#"{"method":"item/commandExecution/outputDelta","params":{"itemId":"x","delta":"Fra:1 Mem:12M"}}"#))
        #expect(unread(#"{"method":"thread/tokenUsage/updated","params":{}}"#))
        for line in Self.recorded.split(separator: "\n") { #expect(!unread(String(line)), "\(line.prefix(80))") }
        // A request is never dropped, whatever it is called.
        #expect(!unread(#"{"method":"item/commandExecution/outputDelta","id":4,"params":{}}"#))
        // A step names a command shortened, not whole.
        let long = "blender -b " + String(repeating: "x", count: 400)
        let started = #"{"method":"item/started","params":{"item":{"type":"commandExecution","id":"c","command":"\#(long)"}}}"#
        guard case .activity(.tool(name: "Command", let summary))? = AgentChatWireParser.parse(started, provider: .codex).first
        else { Issue.record("no step"); return }
        #expect((summary?.count ?? 0) < 200)
    }

    @Test func allowIsOnceAndEverythingElseDeclines() {
        #expect(AgentCodexRun.decision(.allow) as NSDictionary == ["decision": "accept"])
        #expect(AgentCodexRun.decision(.deny) as NSDictionary == ["decision": "decline"])
        let rule = AgentToolApprovalRequest(id: "x", hookPayload: Data(#"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8))!.alwaysAllowRule!
        #expect(AgentCodexRun.decision(.alwaysAllow(rule)) as NSDictionary == ["decision": "decline"])
    }

    @Test func aWrappedCommandIsShownUnwrappedOnlyWhereNothingIsHidden() {
        #expect(AgentCodexRun.shown("/bin/zsh -lc 'blender -b'") == "blender -b")
        // A quote inside could end the body early: shown whole.
        #expect(AgentCodexRun.shown("/bin/zsh -lc 'a' ; rm x ; 'b'") == "/bin/zsh -lc 'a' ; rm x ; 'b'")
        #expect(AgentCodexRun.shown("blender -b") == "blender -b")
    }

    @Test func everyThreadIsOpenedAskingThePersonInTheWorkspaceSandbox() {
        let workspace = URL(fileURLWithPath: "/tmp/w")
        for threadID in [nil, "t1"] as [String?] {
            let open = AgentCodexRun.open(threadID: threadID, workspace: workspace, model: "gpt-6.2-sol")
            #expect(open.method == (threadID == nil ? "thread/start" : "thread/resume"))
            #expect(open.params["approvalsReviewer"] as? String == "user")
            #expect(open.params["approvalPolicy"] as? String == "on-request")
            #expect(open.params["sandbox"] as? String == "workspace-write")
            #expect(open.params["cwd"] as? String == "/tmp/w")
            #expect(open.params["model"] as? String == "gpt-6.2-sol")
            #expect(open.params["threadId"] as? String == threadID)
        }
        let server = LampAgentMCPConfiguration(
            helperExecutableURL: URL(fileURLWithPath: "/A/lamp-mcp"), libraryRootURL: URL(fileURLWithPath: "/lib"),
            policyURL: URL(fileURLWithPath: "/p.json"), workspaceURL: workspace
        )
        let arguments = AgentCodexRun.launchArguments(writingServer: server, effort: "high")
        #expect(arguments.first == "app-server")
        #expect(arguments.contains { $0.hasPrefix("mcp_servers.lamp={command=\"/A/lamp-mcp\"") })
        #expect(arguments.contains { $0.hasPrefix("model_reasoning_effort=") && $0.contains("high") })
    }

    @Test func aMissingThreadAFailedTurnAndAFinalErrorAreFailures() {
        let missing = #"{"error":{"code":-32600,"message":"no rollout found for thread id 0000"},"id":2}"#
        #expect(AgentChatWireParser.parse(missing, provider: .codex) == [.failure("no rollout found for thread id 0000")])
        #expect(AgentChatResumeFailure.indicatesMissingSession(in: missing))
        let failed = #"{"method":"turn/completed","params":{"turn":{"id":"u","status":"failed","error":{"message":"You've hit your usage limit.","codexErrorInfo":"usageLimitExceeded"}}}}"#
        #expect(AgentChatWireParser.parse(failed, provider: .codex) == [.failure("You've hit your usage limit.")])
        let retrying = #"{"method":"error","params":{"error":{"message":"Reconnecting…"},"willRetry":true,"threadId":"t","turnId":"u"}}"#
        #expect(AgentChatWireParser.parse(retrying, provider: .codex).isEmpty)
        let final = #"{"method":"error","params":{"error":{"message":"Stream disconnected"},"willRetry":false,"threadId":"t","turnId":"u"}}"#
        #expect(AgentChatWireParser.parse(final, provider: .codex) == [.failure("Stream disconnected")])
        // And `codex exec` lines read as before.
        #expect(AgentChatWireParser.parse(#"{"type":"thread.started","thread_id":"x"}"#, provider: .codex) == [.sessionStarted("x")])
    }
}

/// The runner against a fake Codex: a shell script that answers Lamp's
/// three requests, asks to run a command, logs what Lamp sent, and touches a
/// marker file only on `accept`.
@Suite(.serialized)
struct AgentCodexRunnerTests {
    struct Fake {
        let folder: URL
        var script: URL { folder.appendingPathComponent("codex") }
        var log: URL { folder.appendingPathComponent("sent.log") }
        var marker: URL { folder.appendingPathComponent("ran") }
        var sent: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
        var ran: Bool { FileManager.default.fileExists(atPath: marker.path) }
    }

    /// `threadReply` answers thread/start or thread/resume; `requests` are
    /// asked after the turn starts, each awaiting Lamp's answer.
    private func fake(
        threadReply: String = #"{"id":2,"result":{"thread":{"id":"t1"}}}"#,
        requests: [String] = [#"{"method":"item/commandExecution/requestApproval","id":0,"params":{"kind":"command","command":"/bin/zsh -lc 'blender -b'","cwd":"/w","reason":"GPU"}}"#]
    ) throws -> Fake {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fake = Fake(folder: folder)
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        var lines = [
            "#!/bin/sh",
            "log=\(quoted(fake.log.path)); marker=\(quoted(fake.marker.path))",
            #"read -r l; printf '%s\n' "$l" >> "$log"; echo '{"id":1,"result":{}}'"#,
            #"read -r l; printf '%s\n' "$l" >> "$log""#,
            #"read -r l; printf '%s\n' "$l" >> "$log"; echo \#(quoted(threadReply))"#,
            #"case "$(tail -n 1 "$log")" in *'"error"'*) ;; esac"#,
        ]
        if threadReply.contains("\"error\"") {
            lines.append(#"while read -r l; do printf '%s\n' "$l" >> "$log"; done; exit 0"#)
        } else {
            lines += [
                #"read -r l; printf '%s\n' "$l" >> "$log"; echo '{"id":3,"result":{"turn":{"id":"u1"}}}'"#,
                #"echo '{"method":"turn/started","params":{"threadId":"t1","turn":{"id":"u1"}}}'"#,
                #"echo '{"method":"item/started","params":{"item":{"type":"agentMessage","id":"c1","text":"","phase":"commentary"}}}'"#,
                #"echo '{"method":"item/agentMessage/delta","params":{"itemId":"c1","delta":"Checking the folder first."}}'"#,
                #"echo '{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"c1","text":"Checking the folder first.","phase":"commentary"}}}'"#,
            ]
            for request in requests {
                lines += [
                    "echo \(quoted(request))",
                    // Until an answer comes: a Stop's interrupt is not one.
                    #"while read -r l; do printf '%s\n' "$l" >> "$log"; case "$l" in *'"decision"'*|*'"error"'*|*'"result"'*) break;; esac; done"#,
                    #"case "$l" in *'"accept"'*) touch "$marker";; esac"#,
                ]
            }
            lines += [
                #"echo '{"method":"item/started","params":{"item":{"type":"agentMessage","id":"m1","text":"","phase":"final_answer"}}}'"#,
                #"echo '{"method":"item/agentMessage/delta","params":{"itemId":"m1","delta":"Done."}}'"#,
                #"echo '{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"m1","text":"Done.","phase":"final_answer"}}}'"#,
                #"echo '{"method":"turn/completed","params":{"threadId":"t1","turn":{"id":"u1","status":"completed"}}}'"#,
                #"while read -r l; do printf '%s\n' "$l" >> "$log"; done; exit 0"#,
            ]
        }
        try lines.joined(separator: "\n").write(to: fake.script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.script.path)
        return fake
    }

    private func run(
        _ fake: Fake, runner: AgentCLIProcessRunner = AgentCLIProcessRunner(), threadID: String? = nil,
        answerSeconds: Double = 30, onApprovals: (@Sendable (AgentCLIProcessRunner, [AgentToolApprovalRequest]) -> Void)? = nil
    ) async -> AgentCLIProcessResult {
        await runner.runCodexAppServer(
            executableName: fake.script.path, workingDirectory: fake.folder, writingServer: nil,
            threadID: threadID, model: nil, effort: nil, prompt: "Render it", answerSeconds: answerSeconds,
            onApprovals: { list in onApprovals?(runner, list) }
        )
    }

    @Test func allowedOnceTheCommandRunsAndTheTurnEnds() async throws {
        let fake = try fake()
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let result = await run(fake) { runner, list in
            guard let request = list.first else { return }
            DispatchQueue.global().async { runner.answerCodexApproval(request.id, with: .allow) }
        }
        #expect(result.exitCode == 0)
        #expect(fake.ran)
        #expect(AgentChatRunSummary.summarize(output: result.output, provider: .codex).response == "Done.")
        #expect(AgentChatRunSummary.summarize(output: result.output, provider: .codex).sessionID == "t1")
        // Its commentary is not part of the reply, as it streams or after.
        #expect(!result.output.contains("Checking the folder first."))
        #expect(fake.sent.contains(#""approvalsReviewer":"user""#))
        #expect(fake.sent.contains(#""approvalPolicy":"on-request""#))
        #expect(fake.sent.contains(#""method":"initialized""#))
    }

    @Test func deniedItDoesNotRun() async throws {
        let fake = try fake()
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let result = await run(fake) { runner, list in
            guard let request = list.first else { return }
            DispatchQueue.global().async { runner.answerCodexApproval(request.id, with: .deny) }
        }
        #expect(result.exitCode == 0)
        #expect(!fake.ran)
        #expect(fake.sent.contains(#""decision":"decline""#))
    }

    @Test func unansweredItIsDeclinedInTime() async throws {
        let fake = try fake()
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let shown = Locked<[Int]>([])
        let result = await run(fake, answerSeconds: 0.5) { _, list in shown.mutate { $0.append(list.count) } }
        #expect(result.exitCode == 0)
        #expect(!fake.ran)
        #expect(fake.sent.contains(#""decision":"decline""#))
        // Shown, then taken away.
        #expect(shown.value.first == 1)
        #expect(shown.value.last == 0)
    }

    @Test func stopWhileItWaitsNeverAllowsIt() async throws {
        let fake = try fake()
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let late = Locked<Bool?>(nil)
        _ = await run(fake) { runner, list in
            guard let request = list.first else { return }
            DispatchQueue.global().async {
                runner.cancel()
                // An Allow pressed after Stop finds nothing waiting.
                Thread.sleep(forTimeInterval: 0.3)
                late.mutate { $0 = runner.answerCodexApproval(request.id, with: .allow) }
            }
        }
        #expect(!fake.ran)
        for _ in 0..<40 where late.value == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(late.value == false)
        #expect(fake.sent.contains(#""method":"turn/interrupt""#))
        #expect(!fake.sent.contains(#""decision":"accept""#))
    }

    /// An Allow that lands the instant after Stop, before the turn has heard
    /// of it, is still a no.
    @Test func allowRightAfterStopIsStillANo() async throws {
        let fake = try fake()
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        _ = await run(fake) { runner, list in
            guard let request = list.first else { return }
            DispatchQueue.global().async {
                runner.cancel()
                runner.answerCodexApproval(request.id, with: .allow)
            }
        }
        #expect(!fake.ran)
        #expect(!fake.sent.contains(#""decision":"accept""#))
    }

    /// A server that ends before the protocol says anything is explained by
    /// what it printed.
    @Test func aServerThatDiesAtStartSaysWhy() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("codex")
        try "#!/bin/sh\necho 'Error: CODEX_HOME is not a directory' >&2\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let result = await AgentCLIProcessRunner().runCodexAppServer(
            executableName: script.path, workingDirectory: folder, writingServer: nil,
            threadID: nil, model: nil, effort: nil, prompt: "Hi"
        )
        #expect(result.exitCode == 1)
        #expect(result.launchError == "Codex stopped before answering: Error: CODEX_HOME is not a directory")
    }

    /// Asked again after Stop, it is declined where it stands, never shown.
    @Test func aRequestAfterStopIsDeclinedUnshown() async throws {
        let fake = try fake(requests: [
            #"{"method":"item/commandExecution/requestApproval","id":0,"params":{"command":"blender -b"}}"#,
            #"{"method":"item/commandExecution/requestApproval","id":1,"params":{"command":"blender -b again"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let shown = Locked<Set<String>>([])
        _ = await run(fake) { runner, list in
            shown.mutate { $0.formUnion(list.map(\.id)) }
            if list.first?.id == "codex-0" { runner.cancel() }
        }
        #expect(shown.value == ["codex-0"])
        #expect(!fake.ran)
        let answers = fake.sent.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.filter { $0["id"] as? Int == 1 && $0["result"] != nil }
        #expect(answers.count == 1, "\(fake.sent)")
        #expect((answers.first?["result"] as? [String: Any])?["decision"] as? String == "decline")
    }

    @Test func requestsLampHasNoPartInAreAnsweredAtOnce() async throws {
        let fake = try fake(requests: [
            #"{"method":"item/permissions/requestApproval","id":5,"params":{}}"#,
            #"{"method":"item/tool/call","id":6,"params":{}}"#,
            #"{"method":"item/commandExecution/requestApproval","id":7,"params":{"command":"curl x","networkApprovalContext":{"host":"x","protocol":"https"}}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let asked = Locked(false)
        let result = await run(fake) { _, list in if !list.isEmpty { asked.mutate { $0 = true } } }
        #expect(result.exitCode == 0)
        #expect(!asked.value)
        #expect(!fake.ran)
        #expect(fake.sent.contains(#""id":5"#) && fake.sent.contains(#""scope":"turn""#))
        #expect(fake.sent.contains(#""id":6"#) && fake.sent.contains("Lamp does not provide item/tool/call."))
        #expect(fake.sent.contains(#""id":7"#))
    }

    @Test func aThreadCodexNoLongerHasReachesTheResumePath() async throws {
        let fake = try fake(threadReply: #"{"error":{"code":-32600,"message":"no rollout found for thread id gone"},"id":2}"#)
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let result = await run(fake, threadID: "gone")
        #expect(result.exitCode == 1)
        #expect(AgentChatResumeFailure.indicatesMissingSession(in: result.output))
        #expect(fake.sent.contains(#""method":"thread/resume""#) && fake.sent.contains(#""threadId":"gone""#))
        #expect(!fake.sent.contains("turn/start"))
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

import Quickshell
import Quickshell.Io

// One remote download helper. Three of these run in parallel from RemoteWall;
// the helper prints JSON progress lines and then the finished path.
Process {
    id: worker

    property string slotKey: ""
    property int slotSeq: 0

    signal progressLine(string key, string line)
    signal jobFinished(string key, int seq, int code)

    stderr: StdioCollector {
        onStreamFinished: {
            if (text.trim() !== "")
                console.warn("remote-wall:", text.trim());
        }
    }
    stdout: SplitParser {
        onRead: (line) => worker.progressLine(worker.slotKey, line)
    }
    onExited: (code) => {
        const key = worker.slotKey;
        const seq = worker.slotSeq;
        worker.slotKey = "";
        worker.slotSeq = 0;
        worker.jobFinished(key, seq, code);
    }
}

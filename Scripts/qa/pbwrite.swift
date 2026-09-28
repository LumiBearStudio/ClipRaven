// QA 클립보드 주입 도구 (테스트 계획 0단계 E4).
//
//   swift Scripts/qa/pbwrite.swift <kind> [value]
//
// kind:
//   text <문자열>        일반 텍스트
//   url <주소>           URL (public.url + 텍스트)
//   rtf <문자열>         서식 있는 텍스트(굵게) + 일반 텍스트
//   image <파일 경로>     PNG/JPEG/TIFF 이미지
//   file <파일 경로>      Finder 에서 파일을 복사한 것과 같은 파일 URL
//   concealed <문자열>   비밀번호 관리자처럼 org.nspasteboard.ConcealedType 표시
//   transient <문자열>   org.nspasteboard.TransientType 표시
//
// 옵션: --pasteboard <이름> 이면 일반 클립보드 대신 이름 붙은 보드에 쓴다(도구 자체
// 점검용 — ClipRaven 은 일반 클립보드만 감시하므로 기록되지 않는다).
//
// 주의: 일반 클립보드에 쓰면 실행 중인 모든 클립보드 앱이 기록한다. E2E 중에는
// 평소 쓰는 ClipRaven 의 캡처를 일시정지하거나 종료해 둔다.
import AppKit

var args = Array(CommandLine.arguments.dropFirst())
var board = NSPasteboard.general
if let i = args.firstIndex(of: "--pasteboard"), i + 1 < args.count {
    board = NSPasteboard(name: NSPasteboard.Name(args[i + 1]))
    args.removeSubrange(i...(i + 1))
}
guard let kind = args.first else {
    FileHandle.standardError.write("usage: pbwrite.swift <text|url|rtf|image|file|concealed|transient> [value] [--pasteboard name]\n".data(using: .utf8)!)
    exit(64)
}
let value = args.dropFirst().joined(separator: " ")
let item = NSPasteboardItem()

switch kind {
case "text":
    item.setString(value, forType: .string)
case "url":
    item.setString(value, forType: .URL)
    item.setString(value, forType: .string)
case "rtf":
    let attr = NSAttributedString(string: value, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
    if let rtf = attr.rtf(from: NSRange(location: 0, length: attr.length), documentAttributes: [:]) {
        item.setData(rtf, forType: .rtf)
    }
    item.setString(value, forType: .string)
case "image":
    guard let image = NSImage(contentsOfFile: value), let tiff = image.tiffRepresentation else {
        FileHandle.standardError.write("cannot read image: \(value)\n".data(using: .utf8)!); exit(66)
    }
    item.setData(tiff, forType: .tiff)
    if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        item.setData(png, forType: .png)
    }
case "file":
    let url = URL(fileURLWithPath: value)
    guard FileManager.default.fileExists(atPath: url.path) else {
        FileHandle.standardError.write("no such file: \(value)\n".data(using: .utf8)!); exit(66)
    }
    item.setString(url.absoluteString, forType: .fileURL)
case "concealed", "transient":
    item.setString(value, forType: .string)
    let marker = kind == "concealed" ? "org.nspasteboard.ConcealedType" : "org.nspasteboard.TransientType"
    item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
default:
    FileHandle.standardError.write("unknown kind: \(kind)\n".data(using: .utf8)!); exit(64)
}

board.clearContents()
guard board.writeObjects([item]) else {
    FileHandle.standardError.write("write failed\n".data(using: .utf8)!); exit(1)
}
print("wrote \(kind) → \(board.name.rawValue) (changeCount \(board.changeCount))")

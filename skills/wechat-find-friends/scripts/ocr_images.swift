import Foundation
import Vision
import ImageIO
let data=FileHandle.standardInput.readDataToEndOfFile()
guard let paths=(try? JSONSerialization.jsonObject(with:data)) as? [String] else {
    fputs("Expected a JSON array of image paths on stdin\n",stderr);exit(2)
}
for path in paths {
    var result:[String:Any]=["path":path]
    do {
        let request=VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans","en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.004
        let handler=VNImageRequestHandler(url:URL(fileURLWithPath:path),options:[:])
        try handler.perform([request])
        result["lines"]=(request.results ?? []).compactMap { item -> [String:Any]? in
            guard let c=item.topCandidates(1).first else{return nil}
            let b=item.boundingBox
            return ["text":c.string,"confidence":c.confidence,"box":[b.minX,b.minY,b.width,b.height]]
        }
    }catch {result["error"]=error.localizedDescription}
    let bytes=try! JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])
    print(String(data:bytes,encoding:.utf8)!)
}

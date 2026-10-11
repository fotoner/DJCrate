// DJCrate의 레코드 세 장과 크레이트를 Icon Composer용 SVG 레이어로 만든다.
// 사용: swift scripts/make-icon.swift [출력 폴더, 기본 Assets/AppIcon.icon/Assets]
// 배경·모서리·빛 반사는 Composer와 시스템이 입힌다. 레이어는 1024 정사각 캔버스를 공유한다.
import Foundation

let output = URL(filePath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "Assets/AppIcon.icon/Assets")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func write(_ name: String, _ content: String) throws {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
    \(content)
    </svg>

    """
    try Data(svg.utf8).write(to: output.appending(path: name))
}

// 기존 원판·라벨 위치와 덱 3밴드 색을 유지한다. 작은 크기에서 사라지는 홈과 흰 반사 호는 뺐다.
let records: [(String, Double, Double, String)] = [
    ("01-record-blue.svg", 344.064, 450.9696, "#3b70f5"),
    ("02-record-orange.svg", 512, 400.5888, "#f0a33d"),
    ("03-record-white.svg", 679.936, 467.7632, "#f2f0e8"),
]
for (name, x, y, label) in records {
    try write(name, """
      <defs>
        <linearGradient id="disc" x1="0" y1="0" x2="1" y2="1">
          <stop stop-color="#33333d"/><stop offset="1" stop-color="#0f0f14"/>
        </linearGradient>
      </defs>
      <circle cx="\(x)" cy="\(y)" r="209.92" fill="url(#disc)"/>
      <circle cx="\(x)" cy="\(y)" r="75.5712" fill="\(label)"/>
      <circle cx="\(x)" cy="\(y)" r="12.5952" fill="#0a0b0f"/>
    """)
}

// 크레이트 앞판의 색·손잡이는 유지하고, 윗면의 밝은 반사 선은 시스템 효과에 맡긴다.
try write("04-crate.svg", """
  <defs>
    <linearGradient id="wood" x1="0" y1="0" x2="0" y2="1">
      <stop stop-color="#fa9e38"/><stop offset="1" stop-color="#db661a"/>
    </linearGradient>
  </defs>
  <rect x="192.9216" y="545.5872" width="638.1568" height="285.4912" rx="35.84" fill="url(#wood)"/>
  <path d="M213.4016 640.7509H810.5984 M213.4016 735.9147H810.5984" stroke="#8c380a" stroke-opacity="0.55" stroke-width="8.192"/>
  <rect x="403.5133" y="591.2658" width="216.9733" height="39.9688" rx="19.9844" fill="#4d1c05"/>
""")
print("아이콘 레이어: \(output.path)")

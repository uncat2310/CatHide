import CoreGraphics
import Foundation

// 自动识别: the rules that decide which recognised text is sensitive. Ported from the Windows
// version (src/lib/sensitive.ts) so both apps suggest the same things. Text and boxes come from
// Apple Vision (SensitiveDetector.swift); everything runs on this Mac.

public enum PrivacyKind: String, CaseIterable, Identifiable, Sendable {
    case phone, email, id, card, address, name, birth, plate, social, number, code

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .phone: "电话"
        case .email: "邮箱"
        case .id: "证件号"
        case .card: "银行卡"
        case .address: "地址"
        case .name: "姓名"
        case .birth: "生日"
        case .plate: "车牌"
        case .social: "社交账号"
        case .number: "编号"
        case .code: "二维码"
        }
    }

    /// Order of the category chips.
    public static let displayOrder: [PrivacyKind] = [
        .phone, .address, .name, .email, .id, .birth, .card, .plate, .social, .number, .code
    ]
}

/// One recognised line of text. Rects are image pixels with the origin at the TOP-left.
public struct RecognizedTextLine: Sendable {
    public let text: String
    /// Box of every UTF-16 unit of `text` (nil for spaces and the second half of surrogate pairs).
    public let glyphs: [CGRect?]

    public init(text: String, glyphs: [CGRect?]) {
        self.text = text
        self.glyphs = glyphs
    }

    public var rect: CGRect {
        glyphs.compactMap { $0 }.reduce(CGRect.null) { $0.union($1) }
    }
}

/// Something that looks sensitive. `rect`: image pixels, origin at the top-left.
public struct SensitiveFinding: Sendable, Equatable {
    public let kind: PrivacyKind
    public let text: String
    public let rect: CGRect

    public init(kind: PrivacyKind, text: String, rect: CGRect) {
        self.kind = kind
        self.text = text
        self.rect = rect
    }
}

private struct Regex: @unchecked Sendable {
    let re: NSRegularExpression
    init(_ pattern: String, caseInsensitive: Bool = false) {
        // Patterns are fixed; a typo should fail loudly in development.
        re = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    func matches(_ s: String) -> [NSTextCheckingResult] {
        re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    func firstMatch(_ s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    /// Like JavaScript's `replace` without the g flag: only the first match.
    func replaceFirst(_ s: String, with replacement: String = "") -> String {
        guard let m = firstMatch(s) else { return s }
        return (s as NSString).replacingCharacters(in: m.range, with: replacement)
    }

    func test(_ s: String) -> Bool { firstMatch(s) != nil }
}

private struct Rule: Sendable {
    let kind: PrivacyKind
    let regex: Regex
    /// Capture group to cover (0: the whole match).
    let group: Int
    /// Final say on a match (checksums, trimming); nil drops it.
    let check: (@Sendable (String) -> String?)?

    init(_ kind: PrivacyKind, _ pattern: String, i: Bool = false, group: Int = 0, check: (@Sendable (String) -> String?)? = nil) {
        self.kind = kind
        self.regex = Regex(pattern, caseInsensitive: i)
        self.group = group
        self.check = check
    }
}

public enum SensitiveRules {
    // ICU spells JavaScript's ASCII-only \b explicitly (ICU's \b also treats Chinese as letters).
    private static let bL = "(?<![A-Za-z0-9_])"
    private static let bR = "(?![A-Za-z0-9_])"
    private static let cjk = "\\u3400-\\u9fff"

    private static func digits(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.map(Character.init))
    }

    static func luhn(_ num: String) -> Bool {
        let ds = num.compactMap { $0.wholeNumberValue }
        guard !ds.isEmpty else { return false }
        var sum = 0
        for (i, d0) in ds.reversed().enumerated() {
            var d = d0
            if i % 2 == 1 { d = d * 2 > 9 ? d * 2 - 9 : d * 2 }
            sum += d
        }
        return sum % 10 == 0
    }

    private static let nameStop = Regex("(电话|手机|联系|地址|号码|微信|邮箱|身份|性别|年龄|出生|民族|籍贯|先生|女士).*$")

    /// Labels a name follows: 姓名：张三, 收件人 李四, 患者 王五…
    private static let nameLabels =
        "收件人|收货人|寄件人|联系人|姓名|名字|户名|开户名|持卡人|签名|签字|经办人|负责人|法定代表人|法人代表|患者|病人|就诊人|监护人|家长|户主|被保险人|投保人|受益人|收款人|付款人|经手人|审核人|审批人|填表人|申请人|Name|Recipient"
    /// Common Chinese surnames (the large majority of people) and compound ones.
    private static let surnames =
        "王李张刘陈杨黄赵吴周徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾肖田董袁潘于蒋蔡余杜叶程苏魏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾夏韦付傅方白邹孟熊秦邱江尹薛闫阎段雷侯龙史陶黎贺顾毛郝龚邵万钱严覃武戴莫孔向汤常温康施文牛樊葛邢安齐易乔伍庞颜倪庄聂章鲁岳翟殷詹申欧耿关兰焦俞左柳甘祝包宁尚符舒阮柯纪梅童凌毕单季裴霍涂成苗谷盛曲翁冉骆蓝路游辛靳管柴蒙鲍华喻祁蒲房滕屈饶解牟艾尤阳时穆农司卓古吉缪简车项连芦麦褚娄窦戚岑景党宫费卜冷晏席卫米柏宗瞿桂全佟应臧闵苟邬边卞姬师和仇栾隋商刁沙荣巫寇桑郎甄丛仲虞敖巩明佘池查麻苑迟邝萧"
    private static let compound = "欧阳|司马|诸葛|上官|慕容|令狐|皇甫|东方|尉迟|公孙|长孙|宇文|司徒|夏侯|澹台|端木|南宫|独孤"
    /// A full Chinese name: surname + one or two characters.
    private static let cnName = "(?:\(compound))[\(cjk)]{1,2}|[\(surnames)][\(cjk)]{1,2}"

    /// Everyday words that happen to start with a surname character (headings, UI labels, chat).
    static let notNames: Set<String> = Set(
        ("王者 张开 陈列 黄色 黄金 周末 周一 周二 周三 周四 周五 周六 周日 周年 周边 周期 高级 高中 高清 高速 何时 马上 马赛克 "
            + "谢谢 于是 许多 曾经 夏天 夏季 田园 任务 任何 方便 方法 方式 方案 方向 金额 白色 白天 万一 钱包 常用 常见 文件 文本 "
            + "文字 文章 文档 安全 安装 安排 齐全 时间 时候 明天 明日 明年 明白 明细 全部 全选 全文 全球 全国 全新 应用 应该 应急 "
            + "和平 和谐 车辆 车票 车主 路线 路过 路口 项目 连接 连续 简介 简单 简历 管理 管道 关于 关闭 关注 包括 包装 包含 包邮 "
            + "成功 成为 成都 单位 单号 季度 华为 华人 温度 康复 施工 严格 武汉 景点 景色 党员 党建 毕业 向前 向后 司机 古代 吉祥 "
            + "牛奶 宁波 江苏 江西 程序 程度 陆续 史上 毛巾 石头 龙头 雷达 卫生 卫星 米饭 尚未 解决 解释 解析 时尚 时长 游戏 游客 "
            + "申请 莫名 孔子 汤圆 罗马 罗列 叶子 林业 宋体 唐朝 韩国 范围 范例 金融 石油 易于 曲线 盛大 骆驼 蓝色 蒙古 房间 房子 "
            + "房东 房租 房屋 师傅 师生 商品 商家 商户 沙发 荣誉 池塘 查询 查看 查找 麻烦 迟到 宗教 冷静 费用 柏林 米兰 戴尔 黎明 "
            + "童年 童话 舒服 舒适 纪念 纪录 梅花 凌晨 单身 苗条 谷歌 艾特 尤其 阳光 阳台 时代 农业 卓越 古典 车站 项链 连衣裙 麦当劳")
            .split(separator: " ").map(String.init)
    )

    /// Words before the address itself: "我的地址是", "寄到", "住在".
    private static let addressLead = Regex("^.*?(?:(?:地址|住址)(?:是|为|在)?[:：]?|(?:寄|送|发|邮)(?:到|往|至)|住在)|^(?:到|往|至|在)")

    private static let wholeChineseName = Regex("^(?:\(cnName))$")

    /// A common surname followed by one or two characters, and not an everyday word.
    public static func looksLikeChineseName(_ s: String) -> Bool {
        !notNames.contains(s) && wholeChineseName.test(s)
    }

    private static func hasLatin(_ s: String) -> Bool {
        s.unicodeScalars.contains { ("A"..."Z").contains($0) || ("a"..."z").contains($0) }
    }

    private static func prefixUTF16(_ s: String, _ n: Int) -> String {
        let ns = s as NSString
        return ns.length <= n ? s : ns.substring(to: n)
    }

    private static let nameCheck: @Sendable (String) -> String? = { t in
        let v = nameStop.replaceFirst(t)
        guard (v as NSString).length >= 2 else { return nil }
        return hasLatin(v) ? v : prefixUTF16(v, 4)
    }

    // Order matters: earlier rules claim their characters first.
    private static let rules: [Rule] = {
        var r: [Rule] = [
            Rule(.email, "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}"),
            // China resident ID (18 digits with a date of birth inside).
            Rule(.id, "(?<!\\d)\\d{6}(?:19|20)\\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\\d|3[01])\\d{3}[\\dXx](?!\\d)"),
            // Singapore NRIC / FIN.
            Rule(.id, "(?<![A-Za-z0-9])[STFGM]\\d{7}[A-Z](?![A-Za-z0-9])", i: true),
            // Hong Kong ID A123456(7), Taiwan ID A123456789, Malaysian IC 900101-14-5678, US SSN, UK NI number.
            Rule(.id, "(?<![A-Za-z0-9])[A-Z]{1,2}\\d{6}\\s?[(（][0-9A][)）]"),
            Rule(.id, "(?<![A-Za-z0-9])[A-Z][12]\\d{8}(?![A-Za-z0-9])"),
            Rule(.id, "(?<![\\d-])\\d{6}-\\d{2}-\\d{4}(?![\\d-])"),
            Rule(.id, "(?<![\\d-])\\d{3}-\\d{2}-\\d{4}(?![\\d-])"),
            Rule(.id, "\(bL)[A-CEGHJ-PR-TW-Z]{2} ?\\d{2} ?\\d{2} ?\\d{2} ?[A-D]\(bR)"),
            // Chinese passports (E / EA / G + digits) and anything after a passport / permit / ID label.
            Rule(.id, "(?<![A-Za-z0-9])(?:E[A-Z]?\\d{7,8}|G\\d{8})(?![A-Za-z0-9])"),
            Rule(.id, "(?:护照(?:号码|号)?|通行证(?:号码|号)?|证件号(?:码)?|身份证(?:号码|号)?|Passport(?: No\\.?| Number)?|NRIC(?: No\\.?)?|FIN(?: No\\.?)?|IC(?: No\\.?)|ID(?: No\\.?| Number))\\s*[:：#]?\\s*([A-Z0-9][A-Z0-9 ()-]{4,}[A-Z0-9)])", i: true, group: 1),
            Rule(.card, "(?<!\\d)\\d(?:[ -]?\\d){12,18}(?!\\d)", check: { t in luhn(digits(t)) ? t : nil }),
            // Card security code and expiry after their labels.
            Rule(.card, "(?:CVV2?|CVC|安全码|验证码)\\s*[:：]?\\s*(\\d{3,4})(?!\\d)", i: true, group: 1),
            Rule(.card, "(?:Exp(?:iry|\\.)?(?: Date)?|Valid (?:Thru|Until)|有效期(?:至)?)\\s*[:：]?\\s*(\\d{2}\\s*/\\s*\\d{2,4})", i: true, group: 1),
            // Date of birth after its label.
            Rule(.birth, "(?:出生(?:日期|年月)?|生日|Date of Birth|DOB|D\\.O\\.B\\.?|Birth ?(?:day|date))\\s*[:：]?\\s*(\\d{4}\\s*[年./-]\\s*\\d{1,2}\\s*[月./-]\\s*\\d{1,2}\\s*日?|\\d{1,2}[./ -]\\d{1,2}[./ -]\\d{2,4}|\\d{1,2} [A-Z][a-z]{2,8},? \\d{4}|[A-Z][a-z]{2,8} \\d{1,2},? \\d{4})", i: true, group: 1),
            // Family tables and forms: 江敏和 19680822 / 张三 1990.03.07 — a compact date right after
            // a name is a date of birth.
            Rule(.birth, "(?:\(cnName))\\s*[:：]?\\s*((?:19|20)\\d{2}[./-]?(?:0[1-9]|1[0-2])[./-]?(?:0[1-9]|[12]\\d|3[01]))(?!\\d)", group: 1),
            // Licence plates: 粤B·D12345 / 京A12345, Singapore SBA 1234 A, or anything after a plate label.
            Rule(.plate, "[京津沪渝冀豫云辽黑湘皖鲁新苏浙赣鄂桂甘晋蒙陕吉闽贵粤青藏川宁琼][A-Z][·• ]?[A-Z0-9]{5,6}(?![A-Za-z0-9])"),
            Rule(.plate, "\(bL)S[A-HJ-NP-Z]{1,2} ?\\d{2,4} ?[A-HJ-NP-Z]\(bR)"),
            Rule(.plate, "(?:车牌(?:号码|号)?|Vehicle(?: No\\.?| Number)?|Plate(?: No\\.?| Number)?)\\s*[:：]?\\s*([A-Z0-9\\u4e00-\\u9fff][A-Z0-9·• -]{4,9}[A-Z0-9])", i: true, group: 1),
            // Chat / social accounts after their labels, and raw WeChat ids.
            Rule(.social, "(?:微信号?|WeChat(?: ID)?|QQ号?|抖音号|小红书号|微博|Telegram|Line(?: ID)?|Instagram|IG|Facebook|Twitter|X|TikTok)\\s*[:：]\\s*(@?[A-Za-z0-9][A-Za-z0-9_.-]{3,30})", i: true, group: 1),
            Rule(.social, "\(bL)wxid_[A-Za-z0-9]{6,}"),
            // Phone numbers, but not a piece of a longer spaced-out number ("6222 0212 3456…").
            Rule(.phone, "(?<![\\d+][ -]?)(?:\\+?86[ -]?)?1[3-9]\\d(?:[ -]?\\d){8}(?![ -]?\\d)"),
            Rule(.phone, "(?<![\\d+][ -]?)(?:\\+?65[ -]?)?[3689]\\d{3}[ -]?\\d{4}(?![ -]?\\d)"),
            Rule(.phone, "\\+\\d{1,3}[ -]?\\d(?:[ -]?\\d){6,13}(?!\\d)"),
            Rule(.phone, "(?<!\\d)0\\d{2,3}-\\d{7,8}(?!\\d)"),
        ]
        // After a label: 收件人 张三 / Name: Tan Ah Kow. Words that also appear in running text
        // (甲方, 房东…) count only when a colon follows (OCR sometimes reads it as 。).
        let labels = [
            "(?:\(nameLabels))[)）]?\\s*[:：。]",
            "(?:出租人|承租人|房东|租客|业主|甲方|乙方|客户|借款人|担保人|老师|学生|员工|医生|Tenant|Landlord|Student|Patient|Full Name|Customer|Applicant|Cardholder|Account Holder|Contact|Attn|Attention|From|To|Signed)[)）]?\\s*[:：。]",
        ]
        for label in labels {
            r.append(Rule(.name, "\(label)\\s*([\(cjk)·]{2,8}|[A-Z][A-Za-z'.-]+(?: [A-Z][A-Za-z'.-]+){0,3})", group: 1, check: nameCheck))
        }
        // Without a colon the label may just be part of a sentence ("黑色签字笔参加笔试"), so what
        // follows counts only when it has the shape of a name: a common surname first.
        r.append(Rule(.name, "(?:\(nameLabels))[)）]?\\s*(\(cnName)|[A-Z][A-Za-z'.-]+(?: [A-Z][A-Za-z'.-]+){0,3})", group: 1, check: { t in
            if notNames.contains(t) { return nil }
            let v = nameStop.replaceFirst(t)
            return (v as NSString).length >= 2 ? v : nil
        }))
        r += [
            // Family members in forms: 父亲 江敏和 / 继母：江春玉 / 配偶 李四. The name has to end the
            // cell (no more Chinese after it), which keeps sentences like 父亲高兴地… out.
            Rule(.name, "(?:[继养生]?[父母]亲?|配偶|妻子|丈夫|爱人|儿子|女儿|兄弟|姐妹|祖父|祖母|外祖父|外祖母|岳父|岳母|公公|婆婆|监护人)\\s*[:：]?\\s*(\(cnName))(?![\(cjk)])", group: 1, check: { t in
                notNames.contains(t) ? nil : t
            }),
            // 王先生 / 李老师 / 张总: surname + honorific, masked together.
            Rule(.name, "(?:\(compound)|[\(surnames)])[\(cjk)]?(?:先生|女士|小姐|老师|同学|经理|医生|律师|主任|阿姨|叔叔|老板|师傅)"),
            // 我是张三 / 我叫李四 / 本人王五 / 签名：赵六, and @张三 mentions.
            Rule(.name, "(?:我是|我叫|本人|签名[:：]?|签字[:：]?)(\(cnName))", group: 1, check: { t in
                if notNames.contains(t) { return nil }
                let v = nameStop.replaceFirst(t)
                return v.isEmpty ? nil : v
            }),
            Rule(.name, "@(\(cnName)|[A-Za-z][\\w.-]{1,24})", group: 1),
            // Mr Tan / Mdm Lim Siew Hua / Dr. Wong / Dear John Smith.
            Rule(.name, "\(bL)(?:Mr|Mrs|Ms|Miss|Mdm|Madam|Dr|Prof)\\.?\\s+[A-Z][a-z]+(?:\\s+[A-Z][a-z]+){0,2}"),
            Rule(.name, "\(bL)(?:Dear|Hi|Hello)\\s+([A-Z][a-z]+\\s+[A-Z][a-z]+(?:\\s+[A-Z][a-z]+)?)", group: 1),
            // A line that is nothing but a Chinese name (form cells, signatures, chat senders): 林小满.
            Rule(.name, "^\\s*(\(cnName))\\s*$", group: 1, check: { t in notNames.contains(t) ? nil : t }),
            // A short Chinese name right before a mobile number, as on parcel labels: 林小满 13912345678.
            Rule(.name, "(?<![\(cjk)])([\(cjk)]{2,3})\\s*(?=(?:\\+?86)?1[3-9]\\d{9}(?!\\d))", group: 1, check: { t in
                let v = nameStop.replaceFirst(t)
                return v.isEmpty ? nil : v
            }),
            // Chinese addresses: …省/市/区/县 … 路/街/号/幢/室…
            Rule(.address, "[\(cjk)]{2,}(?:省|自治区|市|区|县|镇)[\(cjk)A-Za-z0-9 #\\-—()（）]*?(?:路|街|道|巷|弄|村|号|栋|幢|楼|室|单元|大厦|小区|花园|广场|公寓)[\(cjk)A-Za-z0-9#\\-—()（）]*", check: { t in
                let v = addressLead.replaceFirst(t)
                return v.isEmpty ? nil : v
            }),
            // Street and building without the city: 示例路188号…, 7栋2单元1203室.
            Rule(.address, "[\(cjk)]{2,}(?:路|街|大道|大街|巷|弄|胡同)\\d+(?:号|弄)[\(cjk)A-Za-z0-9#\\-]*", check: { t in
                let v = addressLead.replaceFirst(t)
                return v.isEmpty ? nil : v
            }),
            Rule(.address, "\\d+(?:栋|幢|座|号楼)(?:\\d+单元)?\\d+(?:室|号|层)?"),
            // Singapore: Blk 123 …, 12 Orchard Road, #12-34, Singapore 123456.
            Rule(.address, "\(bL)(?:Blk|Block)\\s*\\d+[A-Z]?\(bR).*$", i: true),
            Rule(.address, "\(bL)\\d{1,4}[A-Z]?\\s+(?:[A-Z][a-z]+\\s+){1,4}(?:Road|Rd|Street|St|Avenue|Ave|Drive|Dr|Crescent|Cres|Lane|Ln|Way|Walk|Close|Place|Pl|Link|Central|Rise|View|Park|Boulevard)\(bR).*$"),
            Rule(.address, "#\\d{1,3}-\\d{1,5}[A-Z]?"),
            Rule(.address, "\(bL)(?:Unit|Apt|Apartment|Suite|Flat)\\s*#?\\s*[A-Z0-9-]{1,8}\(bR)"),
            // US / UK style: "Springfield, IL 62704", "London SW1A 1AA".
            Rule(.address, "\(bL)[A-Z][a-z]+(?: [A-Z][a-z]+)?,? [A-Z]{2} \\d{5}(?:-\\d{4})?\(bR)"),
            Rule(.address, "\(bL)[A-Z]{1,2}\\d[A-Z\\d]? \\d[A-Z]{2}\(bR)"),
            Rule(.address, "\(bL)(?:Singapore|S)\\s?\\(?\\d{6}\\)?(?!\\d)"),
            // After a label: 地址：… (rest of the line).
            Rule(.address, "(?:收货地址|收件地址|寄件地址|详细地址|家庭住址|通讯地址|户籍地址|地址|住址|Address|Home Address|Mailing Address)\\s*[:：]\\s*(.{4,})$", i: true, group: 1),
            // Order / tracking / account numbers.
            Rule(.number, "(?:订单号|订单编号|单号|运单号|快递单号|账号|帐号|账户|会员号|会员卡号|卡号|学号|工号|员工号|员工编号|社保卡号|社保号|医保卡号|病历号|住院号|门诊号|保单号|合同编号|发票号码|税号|纳税人识别号|统一社会信用代码|车架号|VIN|Order(?: No\\.?| ID)?|Tracking(?: No\\.?| Number)?|Account(?: No\\.?| Number)?|Policy(?: No\\.?)?|Member(?:ship)? (?:No\\.?|ID)|Employee ID|Staff ID|Student ID|Customer ID|User ID|Invoice No\\.?|Ref(?:erence)?(?: No\\.?)?)\\s*[:：#]?\\s*([A-Za-z0-9][A-Za-z0-9 -]{3,}[A-Za-z0-9])", i: true, group: 1),
            // IPv4 addresses.
            Rule(.number, "(?<![\\d.])(?:(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)\\.){3}(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)(?![\\d.])"),
            Rule(.number, "(?<![A-Za-z0-9])[A-Za-z]{0,4}\\d(?:[ -]?\\d){9,}[A-Za-z]{0,2}(?![A-Za-z0-9])", check: { t in
                datePrefix.test(t) || dateRange.test(t) ? nil : t
            }),
        ]
        return r
    }()

    /// Periods such as 200609-201208 or 20180801 - 20220630 (school and work history).
    private static let dateRange = Regex("^(?:19|20)\\d{2}(?:0[1-9]|1[0-2])(?:\\d{2})?\\s*[-–~至]\\s*(?:19|20)\\d{2}(?:0[1-9]|1[0-2])(?:\\d{2})?$")
    private static let datePrefix = Regex("^(?:19|20)\\d{2}[-/.]\\d{1,2}[-/.]\\d{1,2}")

    static func union(_ glyphs: [CGRect?], _ from: Int, _ to: Int) -> CGRect? {
        var r = CGRect.null
        for i in max(0, from)..<min(glyphs.count, max(from, to)) {
            if let g = glyphs[i] { r = r.union(g) }
        }
        return r.isNull || r.width <= 0 ? nil : r
    }

    /// Everything one line says that looks sensitive.
    public static func matchLine(_ line: RecognizedTextLine) -> [SensitiveFinding] {
        let text = line.text
        let ns = text as NSString
        var taken = [Bool](repeating: false, count: ns.length)
        var out: [SensitiveFinding] = []
        for rule in rules {
            for m in rule.regex.matches(text) {
                let range = m.range(at: rule.group)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                var part = ns.substring(with: range)
                var start = range.location
                if let check = rule.check {
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    guard let kept = check(trimmed), !kept.isEmpty else { continue }
                    let at = (part as NSString).range(of: kept).location
                    guard at != NSNotFound else { continue }
                    start += at
                    part = kept
                }
                let end = start + (part as NSString).length
                guard end <= taken.count, !taken[start..<end].contains(true) else { continue }
                guard let rect = union(line.glyphs, start, end) else { continue }
                for k in start..<end { taken[k] = true }
                out.append(SensitiveFinding(kind: rule.kind, text: part.trimmingCharacters(in: .whitespaces), rect: rect))
            }
        }
        return out
    }

    private static let loneLabel = Regex("^(?:\(nameLabels))[:：]?$")
    private static let valueName = Regex("^[:：]?\\s*(\(cnName)|[A-Z][a-z]+(?: [A-Z][a-z]+){1,3})")

    /// Forms and tables put the label and the name in separate cells, which OCR reads as separate
    /// lines: "姓名" with the name to its right on the same row, or a 姓名 column header with names
    /// below it.
    public static func matchAcrossLines(_ lines: [RecognizedTextLine]) -> [SensitiveFinding] {
        let boxes = lines.map { (r: $0.rect, line: $0) }.filter { !$0.r.isNull }
        var out: [SensitiveFinding] = []

        func take(_ b: (r: CGRect, line: RecognizedTextLine)) -> Bool {
            guard let m = valueName.firstMatch(b.line.text) else { return false }
            let ns = b.line.text as NSString
            var name = ns.substring(with: m.range(at: 1))
            if !hasLatin(name) { name = prefixUTF16(nameStop.replaceFirst(name), 4) }
            guard (name as NSString).length >= 2, !notNames.contains(name) else { return false }
            let from = ns.range(of: name).location
            guard from != NSNotFound,
                  let r = union(b.line.glyphs, from, from + (name as NSString).length) else { return false }
            out.append(SensitiveFinding(kind: .name, text: name, rect: r))
            return true
        }

        for label in boxes {
            let compact = label.line.text.components(separatedBy: .whitespaces).joined()
            guard loneLabel.test(compact) else { continue }
            let h = label.r.height
            let cy = label.r.midY
            // The cell to the right on the same row.
            let right = boxes
                .filter { $0.r != label.r && $0.r.minX > label.r.maxX - 2 && abs($0.r.midY - cy) < h * 0.6 }
                .min { $0.r.minX < $1.r.minX }
            if let right, right.r.minX - label.r.maxX < h * 12, take(right) { continue }
            // A column header: names below it, one per row, until the column ends.
            var y = label.r.maxY
            for _ in 0..<40 {
                guard let below = boxes
                    .filter({ $0.r.minY >= y - 2 && $0.r.minY - y < h * 3 && $0.r.minX < label.r.maxX + h && $0.r.maxX > label.r.minX - h })
                    .min(by: { $0.r.minY < $1.r.minY }) else { break }
                _ = take(below)
                y = below.r.maxY
            }
        }
        return out
    }

    /// Drop repeats (overlapping tiles) and boxes inside a bigger one; sort into reading order.
    public static func dedupe(_ list: [SensitiveFinding]) -> [SensitiveFinding] {
        func area(_ r: CGRect) -> CGFloat { r.width * r.height }
        let sorted = list.sorted { area($0.rect) > area($1.rect) }
        var kept: [SensitiveFinding] = []
        for s in sorted {
            let inside = kept.contains { k in
                let i = k.rect.intersection(s.rect)
                return !i.isNull && area(i) > 0.6 * area(s.rect)
            }
            if !inside { kept.append(s) }
        }
        kept.sort { a, b in
            if abs(a.rect.minY - b.rect.minY) > min(a.rect.height, b.rect.height) / 2 {
                return a.rect.minY < b.rect.minY
            }
            return a.rect.minX < b.rect.minX
        }
        return kept
    }

    /// Rules over all lines (single-line rules, then form cells and table columns).
    public static func findings(in lines: [RecognizedTextLine]) -> [SensitiveFinding] {
        lines.flatMap(matchLine) + matchAcrossLines(lines)
    }
}

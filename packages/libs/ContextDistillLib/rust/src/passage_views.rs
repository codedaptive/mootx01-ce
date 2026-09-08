//! Lossless dependency-group ordering and whole-group UTF-8 skims.
//! Prototype port of tokensaver-lab/views.py, dependency-groups-utf8-v1.
use serde::Serialize;
use std::collections::HashSet;

pub const VERSION: &str = "dependency-groups-utf8-v1";

// Unicode 16.0.0 data generated from Python unicodedata.
fn ranges(encoded: &str) -> Vec<(u32, u32)> {
    encoded
        .split(',')
        .map(|p| {
            let (a, b) = p.split_once('-').unwrap();
            (
                u32::from_str_radix(a, 16).unwrap(),
                u32::from_str_radix(b, 16).unwrap(),
            )
        })
        .collect()
}
fn in_ranges(c: char, rs: &[(u32, u32)]) -> bool {
    let c = c as u32;
    rs.binary_search_by(|(a, b)| {
        if c < *a {
            std::cmp::Ordering::Greater
        } else if c > *b {
            std::cmp::Ordering::Less
        } else {
            std::cmp::Ordering::Equal
        }
    })
    .is_ok()
}
fn word(c: char) -> bool {
    static TABLE: std::sync::OnceLock<Vec<(u32, u32)>> = std::sync::OnceLock::new();
    in_ranges(c,TABLE.get_or_init(||ranges("30-39,41-5a,5f-5f,61-7a,aa-aa,b2-b3,b5-b5,b9-ba,bc-be,c0-d6,d8-f6,f8-2c1,2c6-2d1,2e0-2e4,2ec-2ec,2ee-2ee,370-374,376-377,37a-37d,37f-37f,386-386,388-38a,38c-38c,38e-3a1,3a3-3f5,3f7-481,48a-52f,531-556,559-559,560-588,5d0-5ea,5ef-5f2,620-64a,660-669,66e-66f,671-6d3,6d5-6d5,6e5-6e6,6ee-6fc,6ff-6ff,710-710,712-72f,74d-7a5,7b1-7b1,7c0-7ea,7f4-7f5,7fa-7fa,800-815,81a-81a,824-824,828-828,840-858,860-86a,870-887,889-88e,8a0-8c9,904-939,93d-93d,950-950,958-961,966-96f,971-980,985-98c,98f-990,993-9a8,9aa-9b0,9b2-9b2,9b6-9b9,9bd-9bd,9ce-9ce,9dc-9dd,9df-9e1,9e6-9f1,9f4-9f9,9fc-9fc,a05-a0a,a0f-a10,a13-a28,a2a-a30,a32-a33,a35-a36,a38-a39,a59-a5c,a5e-a5e,a66-a6f,a72-a74,a85-a8d,a8f-a91,a93-aa8,aaa-ab0,ab2-ab3,ab5-ab9,abd-abd,ad0-ad0,ae0-ae1,ae6-aef,af9-af9,b05-b0c,b0f-b10,b13-b28,b2a-b30,b32-b33,b35-b39,b3d-b3d,b5c-b5d,b5f-b61,b66-b6f,b71-b77,b83-b83,b85-b8a,b8e-b90,b92-b95,b99-b9a,b9c-b9c,b9e-b9f,ba3-ba4,ba8-baa,bae-bb9,bd0-bd0,be6-bf2,c05-c0c,c0e-c10,c12-c28,c2a-c39,c3d-c3d,c58-c5a,c5d-c5d,c60-c61,c66-c6f,c78-c7e,c80-c80,c85-c8c,c8e-c90,c92-ca8,caa-cb3,cb5-cb9,cbd-cbd,cdd-cde,ce0-ce1,ce6-cef,cf1-cf2,d04-d0c,d0e-d10,d12-d3a,d3d-d3d,d4e-d4e,d54-d56,d58-d61,d66-d78,d7a-d7f,d85-d96,d9a-db1,db3-dbb,dbd-dbd,dc0-dc6,de6-def,e01-e30,e32-e33,e40-e46,e50-e59,e81-e82,e84-e84,e86-e8a,e8c-ea3,ea5-ea5,ea7-eb0,eb2-eb3,ebd-ebd,ec0-ec4,ec6-ec6,ed0-ed9,edc-edf,f00-f00,f20-f33,f40-f47,f49-f6c,f88-f8c,1000-102a,103f-1049,1050-1055,105a-105d,1061-1061,1065-1066,106e-1070,1075-1081,108e-108e,1090-1099,10a0-10c5,10c7-10c7,10cd-10cd,10d0-10fa,10fc-1248,124a-124d,1250-1256,1258-1258,125a-125d,1260-1288,128a-128d,1290-12b0,12b2-12b5,12b8-12be,12c0-12c0,12c2-12c5,12c8-12d6,12d8-1310,1312-1315,1318-135a,1369-137c,1380-138f,13a0-13f5,13f8-13fd,1401-166c,166f-167f,1681-169a,16a0-16ea,16ee-16f8,1700-1711,171f-1731,1740-1751,1760-176c,176e-1770,1780-17b3,17d7-17d7,17dc-17dc,17e0-17e9,17f0-17f9,1810-1819,1820-1878,1880-1884,1887-18a8,18aa-18aa,18b0-18f5,1900-191e,1946-196d,1970-1974,1980-19ab,19b0-19c9,19d0-19da,1a00-1a16,1a20-1a54,1a80-1a89,1a90-1a99,1aa7-1aa7,1b05-1b33,1b45-1b4c,1b50-1b59,1b83-1ba0,1bae-1be5,1c00-1c23,1c40-1c49,1c4d-1c7d,1c80-1c8a,1c90-1cba,1cbd-1cbf,1ce9-1cec,1cee-1cf3,1cf5-1cf6,1cfa-1cfa,1d00-1dbf,1e00-1f15,1f18-1f1d,1f20-1f45,1f48-1f4d,1f50-1f57,1f59-1f59,1f5b-1f5b,1f5d-1f5d,1f5f-1f7d,1f80-1fb4,1fb6-1fbc,1fbe-1fbe,1fc2-1fc4,1fc6-1fcc,1fd0-1fd3,1fd6-1fdb,1fe0-1fec,1ff2-1ff4,1ff6-1ffc,2070-2071,2074-2079,207f-2089,2090-209c,2102-2102,2107-2107,210a-2113,2115-2115,2119-211d,2124-2124,2126-2126,2128-2128,212a-212d,212f-2139,213c-213f,2145-2149,214e-214e,2150-2189,2460-249b,24ea-24ff,2776-2793,2c00-2ce4,2ceb-2cee,2cf2-2cf3,2cfd-2cfd,2d00-2d25,2d27-2d27,2d2d-2d2d,2d30-2d67,2d6f-2d6f,2d80-2d96,2da0-2da6,2da8-2dae,2db0-2db6,2db8-2dbe,2dc0-2dc6,2dc8-2dce,2dd0-2dd6,2dd8-2dde,2e2f-2e2f,3005-3007,3021-3029,3031-3035,3038-303c,3041-3096,309d-309f,30a1-30fa,30fc-30ff,3105-312f,3131-318e,3192-3195,31a0-31bf,31f0-31ff,3220-3229,3248-324f,3251-325f,3280-3289,32b1-32bf,3400-4dbf,4e00-a48c,a4d0-a4fd,a500-a60c,a610-a62b,a640-a66e,a67f-a69d,a6a0-a6ef,a717-a71f,a722-a788,a78b-a7cd,a7d0-a7d1,a7d3-a7d3,a7d5-a7dc,a7f2-a801,a803-a805,a807-a80a,a80c-a822,a830-a835,a840-a873,a882-a8b3,a8d0-a8d9,a8f2-a8f7,a8fb-a8fb,a8fd-a8fe,a900-a925,a930-a946,a960-a97c,a984-a9b2,a9cf-a9d9,a9e0-a9e4,a9e6-a9fe,aa00-aa28,aa40-aa42,aa44-aa4b,aa50-aa59,aa60-aa76,aa7a-aa7a,aa7e-aaaf,aab1-aab1,aab5-aab6,aab9-aabd,aac0-aac0,aac2-aac2,aadb-aadd,aae0-aaea,aaf2-aaf4,ab01-ab06,ab09-ab0e,ab11-ab16,ab20-ab26,ab28-ab2e,ab30-ab5a,ab5c-ab69,ab70-abe2,abf0-abf9,ac00-d7a3,d7b0-d7c6,d7cb-d7fb,f900-fa6d,fa70-fad9,fb00-fb06,fb13-fb17,fb1d-fb1d,fb1f-fb28,fb2a-fb36,fb38-fb3c,fb3e-fb3e,fb40-fb41,fb43-fb44,fb46-fbb1,fbd3-fd3d,fd50-fd8f,fd92-fdc7,fdf0-fdfb,fe70-fe74,fe76-fefc,ff10-ff19,ff21-ff3a,ff41-ff5a,ff66-ffbe,ffc2-ffc7,ffca-ffcf,ffd2-ffd7,ffda-ffdc,10000-1000b,1000d-10026,10028-1003a,1003c-1003d,1003f-1004d,10050-1005d,10080-100fa,10107-10133,10140-10178,1018a-1018b,10280-1029c,102a0-102d0,102e1-102fb,10300-10323,1032d-1034a,10350-10375,10380-1039d,103a0-103c3,103c8-103cf,103d1-103d5,10400-1049d,104a0-104a9,104b0-104d3,104d8-104fb,10500-10527,10530-10563,10570-1057a,1057c-1058a,1058c-10592,10594-10595,10597-105a1,105a3-105b1,105b3-105b9,105bb-105bc,105c0-105f3,10600-10736,10740-10755,10760-10767,10780-10785,10787-107b0,107b2-107ba,10800-10805,10808-10808,1080a-10835,10837-10838,1083c-1083c,1083f-10855,10858-10876,10879-1089e,108a7-108af,108e0-108f2,108f4-108f5,108fb-1091b,10920-10939,10980-109b7,109bc-109cf,109d2-10a00,10a10-10a13,10a15-10a17,10a19-10a35,10a40-10a48,10a60-10a7e,10a80-10a9f,10ac0-10ac7,10ac9-10ae4,10aeb-10aef,10b00-10b35,10b40-10b55,10b58-10b72,10b78-10b91,10ba9-10baf,10c00-10c48,10c80-10cb2,10cc0-10cf2,10cfa-10d23,10d30-10d39,10d40-10d65,10d6f-10d85,10e60-10e7e,10e80-10ea9,10eb0-10eb1,10ec2-10ec4,10f00-10f27,10f30-10f45,10f51-10f54,10f70-10f81,10fb0-10fcb,10fe0-10ff6,11003-11037,11052-1106f,11071-11072,11075-11075,11083-110af,110d0-110e8,110f0-110f9,11103-11126,11136-1113f,11144-11144,11147-11147,11150-11172,11176-11176,11183-111b2,111c1-111c4,111d0-111da,111dc-111dc,111e1-111f4,11200-11211,11213-1122b,1123f-11240,11280-11286,11288-11288,1128a-1128d,1128f-1129d,1129f-112a8,112b0-112de,112f0-112f9,11305-1130c,1130f-11310,11313-11328,1132a-11330,11332-11333,11335-11339,1133d-1133d,11350-11350,1135d-11361,11380-11389,1138b-1138b,1138e-1138e,11390-113b5,113b7-113b7,113d1-113d1,113d3-113d3,11400-11434,11447-1144a,11450-11459,1145f-11461,11480-114af,114c4-114c5,114c7-114c7,114d0-114d9,11580-115ae,115d8-115db,11600-1162f,11644-11644,11650-11659,11680-116aa,116b8-116b8,116c0-116c9,116d0-116e3,11700-1171a,11730-1173b,11740-11746,11800-1182b,118a0-118f2,118ff-11906,11909-11909,1190c-11913,11915-11916,11918-1192f,1193f-1193f,11941-11941,11950-11959,119a0-119a7,119aa-119d0,119e1-119e1,119e3-119e3,11a00-11a00,11a0b-11a32,11a3a-11a3a,11a50-11a50,11a5c-11a89,11a9d-11a9d,11ab0-11af8,11bc0-11be0,11bf0-11bf9,11c00-11c08,11c0a-11c2e,11c40-11c40,11c50-11c6c,11c72-11c8f,11d00-11d06,11d08-11d09,11d0b-11d30,11d46-11d46,11d50-11d59,11d60-11d65,11d67-11d68,11d6a-11d89,11d98-11d98,11da0-11da9,11ee0-11ef2,11f02-11f02,11f04-11f10,11f12-11f33,11f50-11f59,11fb0-11fb0,11fc0-11fd4,12000-12399,12400-1246e,12480-12543,12f90-12ff0,13000-1342f,13441-13446,13460-143fa,14400-14646,16100-1611d,16130-16139,16800-16a38,16a40-16a5e,16a60-16a69,16a70-16abe,16ac0-16ac9,16ad0-16aed,16b00-16b2f,16b40-16b43,16b50-16b59,16b5b-16b61,16b63-16b77,16b7d-16b8f,16d40-16d6c,16d70-16d79,16e40-16e96,16f00-16f4a,16f50-16f50,16f93-16f9f,16fe0-16fe1,16fe3-16fe3,17000-187f7,18800-18cd5,18cff-18d08,1aff0-1aff3,1aff5-1affb,1affd-1affe,1b000-1b122,1b132-1b132,1b150-1b152,1b155-1b155,1b164-1b167,1b170-1b2fb,1bc00-1bc6a,1bc70-1bc7c,1bc80-1bc88,1bc90-1bc99,1ccf0-1ccf9,1d2c0-1d2d3,1d2e0-1d2f3,1d360-1d378,1d400-1d454,1d456-1d49c,1d49e-1d49f,1d4a2-1d4a2,1d4a5-1d4a6,1d4a9-1d4ac,1d4ae-1d4b9,1d4bb-1d4bb,1d4bd-1d4c3,1d4c5-1d505,1d507-1d50a,1d50d-1d514,1d516-1d51c,1d51e-1d539,1d53b-1d53e,1d540-1d544,1d546-1d546,1d54a-1d550,1d552-1d6a5,1d6a8-1d6c0,1d6c2-1d6da,1d6dc-1d6fa,1d6fc-1d714,1d716-1d734,1d736-1d74e,1d750-1d76e,1d770-1d788,1d78a-1d7a8,1d7aa-1d7c2,1d7c4-1d7cb,1d7ce-1d7ff,1df00-1df1e,1df25-1df2a,1e030-1e06d,1e100-1e12c,1e137-1e13d,1e140-1e149,1e14e-1e14e,1e290-1e2ad,1e2c0-1e2eb,1e2f0-1e2f9,1e4d0-1e4eb,1e4f0-1e4f9,1e5d0-1e5ed,1e5f0-1e5fa,1e7e0-1e7e6,1e7e8-1e7eb,1e7ed-1e7ee,1e7f0-1e7fe,1e800-1e8c4,1e8c7-1e8cf,1e900-1e943,1e94b-1e94b,1e950-1e959,1ec71-1ecab,1ecad-1ecaf,1ecb1-1ecb4,1ed01-1ed2d,1ed2f-1ed3d,1ee00-1ee03,1ee05-1ee1f,1ee21-1ee22,1ee24-1ee24,1ee27-1ee27,1ee29-1ee32,1ee34-1ee37,1ee39-1ee39,1ee3b-1ee3b,1ee42-1ee42,1ee47-1ee47,1ee49-1ee49,1ee4b-1ee4b,1ee4d-1ee4f,1ee51-1ee52,1ee54-1ee54,1ee57-1ee57,1ee59-1ee59,1ee5b-1ee5b,1ee5d-1ee5d,1ee5f-1ee5f,1ee61-1ee62,1ee64-1ee64,1ee67-1ee6a,1ee6c-1ee72,1ee74-1ee77,1ee79-1ee7c,1ee7e-1ee7e,1ee80-1ee89,1ee8b-1ee9b,1eea1-1eea3,1eea5-1eea9,1eeab-1eebb,1f100-1f10c,1fbf0-1fbf9,20000-2a6df,2a700-2b739,2b740-2b81d,2b820-2cea1,2ceb0-2ebe0,2ebf0-2ee5d,2f800-2fa1d,30000-3134a,31350-323af")))
}
fn decimal(c: char) -> bool {
    static TABLE: std::sync::OnceLock<Vec<(u32, u32)>> = std::sync::OnceLock::new();
    in_ranges(c,TABLE.get_or_init(||ranges("30-39,660-669,6f0-6f9,7c0-7c9,966-96f,9e6-9ef,a66-a6f,ae6-aef,b66-b6f,be6-bef,c66-c6f,ce6-cef,d66-d6f,de6-def,e50-e59,ed0-ed9,f20-f29,1040-1049,1090-1099,17e0-17e9,1810-1819,1946-194f,19d0-19d9,1a80-1a89,1a90-1a99,1b50-1b59,1bb0-1bb9,1c40-1c49,1c50-1c59,a620-a629,a8d0-a8d9,a900-a909,a9d0-a9d9,a9f0-a9f9,aa50-aa59,abf0-abf9,ff10-ff19,104a0-104a9,10d30-10d39,10d40-10d49,11066-1106f,110f0-110f9,11136-1113f,111d0-111d9,112f0-112f9,11450-11459,114d0-114d9,11650-11659,116c0-116c9,116d0-116e3,11730-11739,118e0-118e9,11950-11959,11bf0-11bf9,11c50-11c59,11d50-11d59,11da0-11da9,11f50-11f59,16130-16139,16a60-16a69,16ac0-16ac9,16b50-16b59,16d70-16d79,1ccf0-1ccf9,1d7ce-1d7ff,1e140-1e149,1e2f0-1e2f9,1e4f0-1e4f9,1e5f1-1e5fa,1e950-1e959,1fbf0-1fbf9")))
}
fn fold(c: char) -> String {
    static TABLE: std::sync::OnceLock<std::collections::HashMap<char, String>> =
        std::sync::OnceLock::new();
    let table=TABLE.get_or_init(|| "41=61;42=62;43=63;44=64;45=65;46=66;47=67;48=68;49=69;4a=6a;4b=6b;4c=6c;4d=6d;4e=6e;4f=6f;50=70;51=71;52=72;53=73;54=74;55=75;56=76;57=77;58=78;59=79;5a=7a;b5=3bc;c0=e0;c1=e1;c2=e2;c3=e3;c4=e4;c5=e5;c6=e6;c7=e7;c8=e8;c9=e9;ca=ea;cb=eb;cc=ec;cd=ed;ce=ee;cf=ef;d0=f0;d1=f1;d2=f2;d3=f3;d4=f4;d5=f5;d6=f6;d8=f8;d9=f9;da=fa;db=fb;dc=fc;dd=fd;de=fe;df=73,73;100=101;102=103;104=105;106=107;108=109;10a=10b;10c=10d;10e=10f;110=111;112=113;114=115;116=117;118=119;11a=11b;11c=11d;11e=11f;120=121;122=123;124=125;126=127;128=129;12a=12b;12c=12d;12e=12f;130=69,307;132=133;134=135;136=137;139=13a;13b=13c;13d=13e;13f=140;141=142;143=144;145=146;147=148;149=2bc,6e;14a=14b;14c=14d;14e=14f;150=151;152=153;154=155;156=157;158=159;15a=15b;15c=15d;15e=15f;160=161;162=163;164=165;166=167;168=169;16a=16b;16c=16d;16e=16f;170=171;172=173;174=175;176=177;178=ff;179=17a;17b=17c;17d=17e;17f=73;181=253;182=183;184=185;186=254;187=188;189=256;18a=257;18b=18c;18e=1dd;18f=259;190=25b;191=192;193=260;194=263;196=269;197=268;198=199;19c=26f;19d=272;19f=275;1a0=1a1;1a2=1a3;1a4=1a5;1a6=280;1a7=1a8;1a9=283;1ac=1ad;1ae=288;1af=1b0;1b1=28a;1b2=28b;1b3=1b4;1b5=1b6;1b7=292;1b8=1b9;1bc=1bd;1c4=1c6;1c5=1c6;1c7=1c9;1c8=1c9;1ca=1cc;1cb=1cc;1cd=1ce;1cf=1d0;1d1=1d2;1d3=1d4;1d5=1d6;1d7=1d8;1d9=1da;1db=1dc;1de=1df;1e0=1e1;1e2=1e3;1e4=1e5;1e6=1e7;1e8=1e9;1ea=1eb;1ec=1ed;1ee=1ef;1f0=6a,30c;1f1=1f3;1f2=1f3;1f4=1f5;1f6=195;1f7=1bf;1f8=1f9;1fa=1fb;1fc=1fd;1fe=1ff;200=201;202=203;204=205;206=207;208=209;20a=20b;20c=20d;20e=20f;210=211;212=213;214=215;216=217;218=219;21a=21b;21c=21d;21e=21f;220=19e;222=223;224=225;226=227;228=229;22a=22b;22c=22d;22e=22f;230=231;232=233;23a=2c65;23b=23c;23d=19a;23e=2c66;241=242;243=180;244=289;245=28c;246=247;248=249;24a=24b;24c=24d;24e=24f;345=3b9;370=371;372=373;376=377;37f=3f3;386=3ac;388=3ad;389=3ae;38a=3af;38c=3cc;38e=3cd;38f=3ce;390=3b9,308,301;391=3b1;392=3b2;393=3b3;394=3b4;395=3b5;396=3b6;397=3b7;398=3b8;399=3b9;39a=3ba;39b=3bb;39c=3bc;39d=3bd;39e=3be;39f=3bf;3a0=3c0;3a1=3c1;3a3=3c3;3a4=3c4;3a5=3c5;3a6=3c6;3a7=3c7;3a8=3c8;3a9=3c9;3aa=3ca;3ab=3cb;3b0=3c5,308,301;3c2=3c3;3cf=3d7;3d0=3b2;3d1=3b8;3d5=3c6;3d6=3c0;3d8=3d9;3da=3db;3dc=3dd;3de=3df;3e0=3e1;3e2=3e3;3e4=3e5;3e6=3e7;3e8=3e9;3ea=3eb;3ec=3ed;3ee=3ef;3f0=3ba;3f1=3c1;3f4=3b8;3f5=3b5;3f7=3f8;3f9=3f2;3fa=3fb;3fd=37b;3fe=37c;3ff=37d;400=450;401=451;402=452;403=453;404=454;405=455;406=456;407=457;408=458;409=459;40a=45a;40b=45b;40c=45c;40d=45d;40e=45e;40f=45f;410=430;411=431;412=432;413=433;414=434;415=435;416=436;417=437;418=438;419=439;41a=43a;41b=43b;41c=43c;41d=43d;41e=43e;41f=43f;420=440;421=441;422=442;423=443;424=444;425=445;426=446;427=447;428=448;429=449;42a=44a;42b=44b;42c=44c;42d=44d;42e=44e;42f=44f;460=461;462=463;464=465;466=467;468=469;46a=46b;46c=46d;46e=46f;470=471;472=473;474=475;476=477;478=479;47a=47b;47c=47d;47e=47f;480=481;48a=48b;48c=48d;48e=48f;490=491;492=493;494=495;496=497;498=499;49a=49b;49c=49d;49e=49f;4a0=4a1;4a2=4a3;4a4=4a5;4a6=4a7;4a8=4a9;4aa=4ab;4ac=4ad;4ae=4af;4b0=4b1;4b2=4b3;4b4=4b5;4b6=4b7;4b8=4b9;4ba=4bb;4bc=4bd;4be=4bf;4c0=4cf;4c1=4c2;4c3=4c4;4c5=4c6;4c7=4c8;4c9=4ca;4cb=4cc;4cd=4ce;4d0=4d1;4d2=4d3;4d4=4d5;4d6=4d7;4d8=4d9;4da=4db;4dc=4dd;4de=4df;4e0=4e1;4e2=4e3;4e4=4e5;4e6=4e7;4e8=4e9;4ea=4eb;4ec=4ed;4ee=4ef;4f0=4f1;4f2=4f3;4f4=4f5;4f6=4f7;4f8=4f9;4fa=4fb;4fc=4fd;4fe=4ff;500=501;502=503;504=505;506=507;508=509;50a=50b;50c=50d;50e=50f;510=511;512=513;514=515;516=517;518=519;51a=51b;51c=51d;51e=51f;520=521;522=523;524=525;526=527;528=529;52a=52b;52c=52d;52e=52f;531=561;532=562;533=563;534=564;535=565;536=566;537=567;538=568;539=569;53a=56a;53b=56b;53c=56c;53d=56d;53e=56e;53f=56f;540=570;541=571;542=572;543=573;544=574;545=575;546=576;547=577;548=578;549=579;54a=57a;54b=57b;54c=57c;54d=57d;54e=57e;54f=57f;550=580;551=581;552=582;553=583;554=584;555=585;556=586;587=565,582;10a0=2d00;10a1=2d01;10a2=2d02;10a3=2d03;10a4=2d04;10a5=2d05;10a6=2d06;10a7=2d07;10a8=2d08;10a9=2d09;10aa=2d0a;10ab=2d0b;10ac=2d0c;10ad=2d0d;10ae=2d0e;10af=2d0f;10b0=2d10;10b1=2d11;10b2=2d12;10b3=2d13;10b4=2d14;10b5=2d15;10b6=2d16;10b7=2d17;10b8=2d18;10b9=2d19;10ba=2d1a;10bb=2d1b;10bc=2d1c;10bd=2d1d;10be=2d1e;10bf=2d1f;10c0=2d20;10c1=2d21;10c2=2d22;10c3=2d23;10c4=2d24;10c5=2d25;10c7=2d27;10cd=2d2d;13f8=13f0;13f9=13f1;13fa=13f2;13fb=13f3;13fc=13f4;13fd=13f5;1c80=432;1c81=434;1c82=43e;1c83=441;1c84=442;1c85=442;1c86=44a;1c87=463;1c88=a64b;1c89=1c8a;1c90=10d0;1c91=10d1;1c92=10d2;1c93=10d3;1c94=10d4;1c95=10d5;1c96=10d6;1c97=10d7;1c98=10d8;1c99=10d9;1c9a=10da;1c9b=10db;1c9c=10dc;1c9d=10dd;1c9e=10de;1c9f=10df;1ca0=10e0;1ca1=10e1;1ca2=10e2;1ca3=10e3;1ca4=10e4;1ca5=10e5;1ca6=10e6;1ca7=10e7;1ca8=10e8;1ca9=10e9;1caa=10ea;1cab=10eb;1cac=10ec;1cad=10ed;1cae=10ee;1caf=10ef;1cb0=10f0;1cb1=10f1;1cb2=10f2;1cb3=10f3;1cb4=10f4;1cb5=10f5;1cb6=10f6;1cb7=10f7;1cb8=10f8;1cb9=10f9;1cba=10fa;1cbd=10fd;1cbe=10fe;1cbf=10ff;1e00=1e01;1e02=1e03;1e04=1e05;1e06=1e07;1e08=1e09;1e0a=1e0b;1e0c=1e0d;1e0e=1e0f;1e10=1e11;1e12=1e13;1e14=1e15;1e16=1e17;1e18=1e19;1e1a=1e1b;1e1c=1e1d;1e1e=1e1f;1e20=1e21;1e22=1e23;1e24=1e25;1e26=1e27;1e28=1e29;1e2a=1e2b;1e2c=1e2d;1e2e=1e2f;1e30=1e31;1e32=1e33;1e34=1e35;1e36=1e37;1e38=1e39;1e3a=1e3b;1e3c=1e3d;1e3e=1e3f;1e40=1e41;1e42=1e43;1e44=1e45;1e46=1e47;1e48=1e49;1e4a=1e4b;1e4c=1e4d;1e4e=1e4f;1e50=1e51;1e52=1e53;1e54=1e55;1e56=1e57;1e58=1e59;1e5a=1e5b;1e5c=1e5d;1e5e=1e5f;1e60=1e61;1e62=1e63;1e64=1e65;1e66=1e67;1e68=1e69;1e6a=1e6b;1e6c=1e6d;1e6e=1e6f;1e70=1e71;1e72=1e73;1e74=1e75;1e76=1e77;1e78=1e79;1e7a=1e7b;1e7c=1e7d;1e7e=1e7f;1e80=1e81;1e82=1e83;1e84=1e85;1e86=1e87;1e88=1e89;1e8a=1e8b;1e8c=1e8d;1e8e=1e8f;1e90=1e91;1e92=1e93;1e94=1e95;1e96=68,331;1e97=74,308;1e98=77,30a;1e99=79,30a;1e9a=61,2be;1e9b=1e61;1e9e=73,73;1ea0=1ea1;1ea2=1ea3;1ea4=1ea5;1ea6=1ea7;1ea8=1ea9;1eaa=1eab;1eac=1ead;1eae=1eaf;1eb0=1eb1;1eb2=1eb3;1eb4=1eb5;1eb6=1eb7;1eb8=1eb9;1eba=1ebb;1ebc=1ebd;1ebe=1ebf;1ec0=1ec1;1ec2=1ec3;1ec4=1ec5;1ec6=1ec7;1ec8=1ec9;1eca=1ecb;1ecc=1ecd;1ece=1ecf;1ed0=1ed1;1ed2=1ed3;1ed4=1ed5;1ed6=1ed7;1ed8=1ed9;1eda=1edb;1edc=1edd;1ede=1edf;1ee0=1ee1;1ee2=1ee3;1ee4=1ee5;1ee6=1ee7;1ee8=1ee9;1eea=1eeb;1eec=1eed;1eee=1eef;1ef0=1ef1;1ef2=1ef3;1ef4=1ef5;1ef6=1ef7;1ef8=1ef9;1efa=1efb;1efc=1efd;1efe=1eff;1f08=1f00;1f09=1f01;1f0a=1f02;1f0b=1f03;1f0c=1f04;1f0d=1f05;1f0e=1f06;1f0f=1f07;1f18=1f10;1f19=1f11;1f1a=1f12;1f1b=1f13;1f1c=1f14;1f1d=1f15;1f28=1f20;1f29=1f21;1f2a=1f22;1f2b=1f23;1f2c=1f24;1f2d=1f25;1f2e=1f26;1f2f=1f27;1f38=1f30;1f39=1f31;1f3a=1f32;1f3b=1f33;1f3c=1f34;1f3d=1f35;1f3e=1f36;1f3f=1f37;1f48=1f40;1f49=1f41;1f4a=1f42;1f4b=1f43;1f4c=1f44;1f4d=1f45;1f50=3c5,313;1f52=3c5,313,300;1f54=3c5,313,301;1f56=3c5,313,342;1f59=1f51;1f5b=1f53;1f5d=1f55;1f5f=1f57;1f68=1f60;1f69=1f61;1f6a=1f62;1f6b=1f63;1f6c=1f64;1f6d=1f65;1f6e=1f66;1f6f=1f67;1f80=1f00,3b9;1f81=1f01,3b9;1f82=1f02,3b9;1f83=1f03,3b9;1f84=1f04,3b9;1f85=1f05,3b9;1f86=1f06,3b9;1f87=1f07,3b9;1f88=1f00,3b9;1f89=1f01,3b9;1f8a=1f02,3b9;1f8b=1f03,3b9;1f8c=1f04,3b9;1f8d=1f05,3b9;1f8e=1f06,3b9;1f8f=1f07,3b9;1f90=1f20,3b9;1f91=1f21,3b9;1f92=1f22,3b9;1f93=1f23,3b9;1f94=1f24,3b9;1f95=1f25,3b9;1f96=1f26,3b9;1f97=1f27,3b9;1f98=1f20,3b9;1f99=1f21,3b9;1f9a=1f22,3b9;1f9b=1f23,3b9;1f9c=1f24,3b9;1f9d=1f25,3b9;1f9e=1f26,3b9;1f9f=1f27,3b9;1fa0=1f60,3b9;1fa1=1f61,3b9;1fa2=1f62,3b9;1fa3=1f63,3b9;1fa4=1f64,3b9;1fa5=1f65,3b9;1fa6=1f66,3b9;1fa7=1f67,3b9;1fa8=1f60,3b9;1fa9=1f61,3b9;1faa=1f62,3b9;1fab=1f63,3b9;1fac=1f64,3b9;1fad=1f65,3b9;1fae=1f66,3b9;1faf=1f67,3b9;1fb2=1f70,3b9;1fb3=3b1,3b9;1fb4=3ac,3b9;1fb6=3b1,342;1fb7=3b1,342,3b9;1fb8=1fb0;1fb9=1fb1;1fba=1f70;1fbb=1f71;1fbc=3b1,3b9;1fbe=3b9;1fc2=1f74,3b9;1fc3=3b7,3b9;1fc4=3ae,3b9;1fc6=3b7,342;1fc7=3b7,342,3b9;1fc8=1f72;1fc9=1f73;1fca=1f74;1fcb=1f75;1fcc=3b7,3b9;1fd2=3b9,308,300;1fd3=3b9,308,301;1fd6=3b9,342;1fd7=3b9,308,342;1fd8=1fd0;1fd9=1fd1;1fda=1f76;1fdb=1f77;1fe2=3c5,308,300;1fe3=3c5,308,301;1fe4=3c1,313;1fe6=3c5,342;1fe7=3c5,308,342;1fe8=1fe0;1fe9=1fe1;1fea=1f7a;1feb=1f7b;1fec=1fe5;1ff2=1f7c,3b9;1ff3=3c9,3b9;1ff4=3ce,3b9;1ff6=3c9,342;1ff7=3c9,342,3b9;1ff8=1f78;1ff9=1f79;1ffa=1f7c;1ffb=1f7d;1ffc=3c9,3b9;2126=3c9;212a=6b;212b=e5;2132=214e;2160=2170;2161=2171;2162=2172;2163=2173;2164=2174;2165=2175;2166=2176;2167=2177;2168=2178;2169=2179;216a=217a;216b=217b;216c=217c;216d=217d;216e=217e;216f=217f;2183=2184;24b6=24d0;24b7=24d1;24b8=24d2;24b9=24d3;24ba=24d4;24bb=24d5;24bc=24d6;24bd=24d7;24be=24d8;24bf=24d9;24c0=24da;24c1=24db;24c2=24dc;24c3=24dd;24c4=24de;24c5=24df;24c6=24e0;24c7=24e1;24c8=24e2;24c9=24e3;24ca=24e4;24cb=24e5;24cc=24e6;24cd=24e7;24ce=24e8;24cf=24e9;2c00=2c30;2c01=2c31;2c02=2c32;2c03=2c33;2c04=2c34;2c05=2c35;2c06=2c36;2c07=2c37;2c08=2c38;2c09=2c39;2c0a=2c3a;2c0b=2c3b;2c0c=2c3c;2c0d=2c3d;2c0e=2c3e;2c0f=2c3f;2c10=2c40;2c11=2c41;2c12=2c42;2c13=2c43;2c14=2c44;2c15=2c45;2c16=2c46;2c17=2c47;2c18=2c48;2c19=2c49;2c1a=2c4a;2c1b=2c4b;2c1c=2c4c;2c1d=2c4d;2c1e=2c4e;2c1f=2c4f;2c20=2c50;2c21=2c51;2c22=2c52;2c23=2c53;2c24=2c54;2c25=2c55;2c26=2c56;2c27=2c57;2c28=2c58;2c29=2c59;2c2a=2c5a;2c2b=2c5b;2c2c=2c5c;2c2d=2c5d;2c2e=2c5e;2c2f=2c5f;2c60=2c61;2c62=26b;2c63=1d7d;2c64=27d;2c67=2c68;2c69=2c6a;2c6b=2c6c;2c6d=251;2c6e=271;2c6f=250;2c70=252;2c72=2c73;2c75=2c76;2c7e=23f;2c7f=240;2c80=2c81;2c82=2c83;2c84=2c85;2c86=2c87;2c88=2c89;2c8a=2c8b;2c8c=2c8d;2c8e=2c8f;2c90=2c91;2c92=2c93;2c94=2c95;2c96=2c97;2c98=2c99;2c9a=2c9b;2c9c=2c9d;2c9e=2c9f;2ca0=2ca1;2ca2=2ca3;2ca4=2ca5;2ca6=2ca7;2ca8=2ca9;2caa=2cab;2cac=2cad;2cae=2caf;2cb0=2cb1;2cb2=2cb3;2cb4=2cb5;2cb6=2cb7;2cb8=2cb9;2cba=2cbb;2cbc=2cbd;2cbe=2cbf;2cc0=2cc1;2cc2=2cc3;2cc4=2cc5;2cc6=2cc7;2cc8=2cc9;2cca=2ccb;2ccc=2ccd;2cce=2ccf;2cd0=2cd1;2cd2=2cd3;2cd4=2cd5;2cd6=2cd7;2cd8=2cd9;2cda=2cdb;2cdc=2cdd;2cde=2cdf;2ce0=2ce1;2ce2=2ce3;2ceb=2cec;2ced=2cee;2cf2=2cf3;a640=a641;a642=a643;a644=a645;a646=a647;a648=a649;a64a=a64b;a64c=a64d;a64e=a64f;a650=a651;a652=a653;a654=a655;a656=a657;a658=a659;a65a=a65b;a65c=a65d;a65e=a65f;a660=a661;a662=a663;a664=a665;a666=a667;a668=a669;a66a=a66b;a66c=a66d;a680=a681;a682=a683;a684=a685;a686=a687;a688=a689;a68a=a68b;a68c=a68d;a68e=a68f;a690=a691;a692=a693;a694=a695;a696=a697;a698=a699;a69a=a69b;a722=a723;a724=a725;a726=a727;a728=a729;a72a=a72b;a72c=a72d;a72e=a72f;a732=a733;a734=a735;a736=a737;a738=a739;a73a=a73b;a73c=a73d;a73e=a73f;a740=a741;a742=a743;a744=a745;a746=a747;a748=a749;a74a=a74b;a74c=a74d;a74e=a74f;a750=a751;a752=a753;a754=a755;a756=a757;a758=a759;a75a=a75b;a75c=a75d;a75e=a75f;a760=a761;a762=a763;a764=a765;a766=a767;a768=a769;a76a=a76b;a76c=a76d;a76e=a76f;a779=a77a;a77b=a77c;a77d=1d79;a77e=a77f;a780=a781;a782=a783;a784=a785;a786=a787;a78b=a78c;a78d=265;a790=a791;a792=a793;a796=a797;a798=a799;a79a=a79b;a79c=a79d;a79e=a79f;a7a0=a7a1;a7a2=a7a3;a7a4=a7a5;a7a6=a7a7;a7a8=a7a9;a7aa=266;a7ab=25c;a7ac=261;a7ad=26c;a7ae=26a;a7b0=29e;a7b1=287;a7b2=29d;a7b3=ab53;a7b4=a7b5;a7b6=a7b7;a7b8=a7b9;a7ba=a7bb;a7bc=a7bd;a7be=a7bf;a7c0=a7c1;a7c2=a7c3;a7c4=a794;a7c5=282;a7c6=1d8e;a7c7=a7c8;a7c9=a7ca;a7cb=264;a7cc=a7cd;a7d0=a7d1;a7d6=a7d7;a7d8=a7d9;a7da=a7db;a7dc=19b;a7f5=a7f6;ab70=13a0;ab71=13a1;ab72=13a2;ab73=13a3;ab74=13a4;ab75=13a5;ab76=13a6;ab77=13a7;ab78=13a8;ab79=13a9;ab7a=13aa;ab7b=13ab;ab7c=13ac;ab7d=13ad;ab7e=13ae;ab7f=13af;ab80=13b0;ab81=13b1;ab82=13b2;ab83=13b3;ab84=13b4;ab85=13b5;ab86=13b6;ab87=13b7;ab88=13b8;ab89=13b9;ab8a=13ba;ab8b=13bb;ab8c=13bc;ab8d=13bd;ab8e=13be;ab8f=13bf;ab90=13c0;ab91=13c1;ab92=13c2;ab93=13c3;ab94=13c4;ab95=13c5;ab96=13c6;ab97=13c7;ab98=13c8;ab99=13c9;ab9a=13ca;ab9b=13cb;ab9c=13cc;ab9d=13cd;ab9e=13ce;ab9f=13cf;aba0=13d0;aba1=13d1;aba2=13d2;aba3=13d3;aba4=13d4;aba5=13d5;aba6=13d6;aba7=13d7;aba8=13d8;aba9=13d9;abaa=13da;abab=13db;abac=13dc;abad=13dd;abae=13de;abaf=13df;abb0=13e0;abb1=13e1;abb2=13e2;abb3=13e3;abb4=13e4;abb5=13e5;abb6=13e6;abb7=13e7;abb8=13e8;abb9=13e9;abba=13ea;abbb=13eb;abbc=13ec;abbd=13ed;abbe=13ee;abbf=13ef;fb00=66,66;fb01=66,69;fb02=66,6c;fb03=66,66,69;fb04=66,66,6c;fb05=73,74;fb06=73,74;fb13=574,576;fb14=574,565;fb15=574,56b;fb16=57e,576;fb17=574,56d;ff21=ff41;ff22=ff42;ff23=ff43;ff24=ff44;ff25=ff45;ff26=ff46;ff27=ff47;ff28=ff48;ff29=ff49;ff2a=ff4a;ff2b=ff4b;ff2c=ff4c;ff2d=ff4d;ff2e=ff4e;ff2f=ff4f;ff30=ff50;ff31=ff51;ff32=ff52;ff33=ff53;ff34=ff54;ff35=ff55;ff36=ff56;ff37=ff57;ff38=ff58;ff39=ff59;ff3a=ff5a;10400=10428;10401=10429;10402=1042a;10403=1042b;10404=1042c;10405=1042d;10406=1042e;10407=1042f;10408=10430;10409=10431;1040a=10432;1040b=10433;1040c=10434;1040d=10435;1040e=10436;1040f=10437;10410=10438;10411=10439;10412=1043a;10413=1043b;10414=1043c;10415=1043d;10416=1043e;10417=1043f;10418=10440;10419=10441;1041a=10442;1041b=10443;1041c=10444;1041d=10445;1041e=10446;1041f=10447;10420=10448;10421=10449;10422=1044a;10423=1044b;10424=1044c;10425=1044d;10426=1044e;10427=1044f;104b0=104d8;104b1=104d9;104b2=104da;104b3=104db;104b4=104dc;104b5=104dd;104b6=104de;104b7=104df;104b8=104e0;104b9=104e1;104ba=104e2;104bb=104e3;104bc=104e4;104bd=104e5;104be=104e6;104bf=104e7;104c0=104e8;104c1=104e9;104c2=104ea;104c3=104eb;104c4=104ec;104c5=104ed;104c6=104ee;104c7=104ef;104c8=104f0;104c9=104f1;104ca=104f2;104cb=104f3;104cc=104f4;104cd=104f5;104ce=104f6;104cf=104f7;104d0=104f8;104d1=104f9;104d2=104fa;104d3=104fb;10570=10597;10571=10598;10572=10599;10573=1059a;10574=1059b;10575=1059c;10576=1059d;10577=1059e;10578=1059f;10579=105a0;1057a=105a1;1057c=105a3;1057d=105a4;1057e=105a5;1057f=105a6;10580=105a7;10581=105a8;10582=105a9;10583=105aa;10584=105ab;10585=105ac;10586=105ad;10587=105ae;10588=105af;10589=105b0;1058a=105b1;1058c=105b3;1058d=105b4;1058e=105b5;1058f=105b6;10590=105b7;10591=105b8;10592=105b9;10594=105bb;10595=105bc;10c80=10cc0;10c81=10cc1;10c82=10cc2;10c83=10cc3;10c84=10cc4;10c85=10cc5;10c86=10cc6;10c87=10cc7;10c88=10cc8;10c89=10cc9;10c8a=10cca;10c8b=10ccb;10c8c=10ccc;10c8d=10ccd;10c8e=10cce;10c8f=10ccf;10c90=10cd0;10c91=10cd1;10c92=10cd2;10c93=10cd3;10c94=10cd4;10c95=10cd5;10c96=10cd6;10c97=10cd7;10c98=10cd8;10c99=10cd9;10c9a=10cda;10c9b=10cdb;10c9c=10cdc;10c9d=10cdd;10c9e=10cde;10c9f=10cdf;10ca0=10ce0;10ca1=10ce1;10ca2=10ce2;10ca3=10ce3;10ca4=10ce4;10ca5=10ce5;10ca6=10ce6;10ca7=10ce7;10ca8=10ce8;10ca9=10ce9;10caa=10cea;10cab=10ceb;10cac=10cec;10cad=10ced;10cae=10cee;10caf=10cef;10cb0=10cf0;10cb1=10cf1;10cb2=10cf2;10d50=10d70;10d51=10d71;10d52=10d72;10d53=10d73;10d54=10d74;10d55=10d75;10d56=10d76;10d57=10d77;10d58=10d78;10d59=10d79;10d5a=10d7a;10d5b=10d7b;10d5c=10d7c;10d5d=10d7d;10d5e=10d7e;10d5f=10d7f;10d60=10d80;10d61=10d81;10d62=10d82;10d63=10d83;10d64=10d84;10d65=10d85;118a0=118c0;118a1=118c1;118a2=118c2;118a3=118c3;118a4=118c4;118a5=118c5;118a6=118c6;118a7=118c7;118a8=118c8;118a9=118c9;118aa=118ca;118ab=118cb;118ac=118cc;118ad=118cd;118ae=118ce;118af=118cf;118b0=118d0;118b1=118d1;118b2=118d2;118b3=118d3;118b4=118d4;118b5=118d5;118b6=118d6;118b7=118d7;118b8=118d8;118b9=118d9;118ba=118da;118bb=118db;118bc=118dc;118bd=118dd;118be=118de;118bf=118df;16e40=16e60;16e41=16e61;16e42=16e62;16e43=16e63;16e44=16e64;16e45=16e65;16e46=16e66;16e47=16e67;16e48=16e68;16e49=16e69;16e4a=16e6a;16e4b=16e6b;16e4c=16e6c;16e4d=16e6d;16e4e=16e6e;16e4f=16e6f;16e50=16e70;16e51=16e71;16e52=16e72;16e53=16e73;16e54=16e74;16e55=16e75;16e56=16e76;16e57=16e77;16e58=16e78;16e59=16e79;16e5a=16e7a;16e5b=16e7b;16e5c=16e7c;16e5d=16e7d;16e5e=16e7e;16e5f=16e7f;1e900=1e922;1e901=1e923;1e902=1e924;1e903=1e925;1e904=1e926;1e905=1e927;1e906=1e928;1e907=1e929;1e908=1e92a;1e909=1e92b;1e90a=1e92c;1e90b=1e92d;1e90c=1e92e;1e90d=1e92f;1e90e=1e930;1e90f=1e931;1e910=1e932;1e911=1e933;1e912=1e934;1e913=1e935;1e914=1e936;1e915=1e937;1e916=1e938;1e917=1e939;1e918=1e93a;1e919=1e93b;1e91a=1e93c;1e91b=1e93d;1e91c=1e93e;1e91d=1e93f;1e91e=1e940;1e91f=1e941;1e920=1e942;1e921=1e943".split(';').map(|p| {
        let (a,b)=p.split_once('=').unwrap();
        (char::from_u32(u32::from_str_radix(a,16).unwrap()).unwrap(),b.split(',').map(|x|char::from_u32(u32::from_str_radix(x,16).unwrap()).unwrap()).collect())
    }).collect());
    table.get(&c).cloned().unwrap_or_else(|| c.to_string())
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PassageViewResult {
    pub version: String,
    pub text: String,
    pub continuation: String,
    pub full_text: String,
    pub complete: bool,
    pub budget_honored: bool,
    pub budget: usize,
    pub returned_bytes: usize,
    /// Half-open Unicode scalar offsets into the original body, in output order.
    pub spans: Vec<[usize; 2]>,
    pub group_order: Vec<usize>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PassageViewPair {
    pub plain: PassageViewResult,
    pub ordered: PassageViewResult,
}

fn ws(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}
fn trim(s: &[char]) -> &[char] {
    let a = s.iter().position(|c| !ws(*c)).unwrap_or(s.len());
    let b = s.iter().rposition(|c| !ws(*c)).map_or(a, |i| i + 1);
    &s[a..b]
}
fn lines(s: &[char]) -> Vec<(usize, usize)> {
    let mut result = Vec::new();
    let mut a = 0;
    let mut i = 0;
    while i < s.len() {
        if matches!(
            s[i],
            '\n' | '\r'
                | '\u{b}'
                | '\u{c}'
                | '\u{1c}'
                | '\u{1d}'
                | '\u{1e}'
                | '\u{85}'
                | '\u{2028}'
                | '\u{2029}'
        ) {
            if s[i] == '\r' && s.get(i + 1) == Some(&'\n') {
                i += 1;
            }
            result.push((a, i + 1));
            a = i + 1;
        }
        i += 1;
    }
    if a < s.len() {
        result.push((a, s.len()));
    }
    result
}
fn unnewline(s: &[char]) -> &[char] {
    let end = s
        .iter()
        .rposition(|c| *c != '\r' && *c != '\n')
        .map_or(0, |i| i + 1);
    &s[..end]
}
fn indent3(s: &[char]) -> Option<&[char]> {
    let n = s.iter().take_while(|c| **c == ' ').count();
    if n > 3 {
        None
    } else {
        Some(&s[n..])
    }
}
fn marker(s: &[char]) -> Option<(char, usize, &[char])> {
    let s = indent3(s)?;
    let c = *s.first()?;
    if c != '`' && c != '~' {
        return None;
    }
    let n = s.iter().take_while(|x| **x == c).count();
    if n < 3 {
        None
    } else {
        Some((c, n, &s[n..]))
    }
}
fn heading(s: &[char]) -> Option<usize> {
    let s = indent3(s)?;
    let n = s.iter().take_while(|c| **c == '#').count();
    if (1..=6).contains(&n) && s.get(n).is_some_and(|c| ws(*c)) {
        Some(n)
    } else {
        None
    }
}
fn is_list(s: &[char]) -> bool {
    let s = &s[s.iter().position(|c| !ws(*c)).unwrap_or(s.len())..];
    if s.is_empty() {
        return false;
    }
    let n = if matches!(s[0], '-' | '+' | '*') {
        1
    } else {
        let n = s.iter().take_while(|c| decimal(**c)).count();
        if n == 0 || !s.get(n).is_some_and(|c| matches!(c, '.' | ')')) {
            return false;
        }
        n + 1
    };
    s.get(n).is_some_and(|c| ws(*c))
}
fn words(s: &[char]) -> HashSet<String> {
    let folded: Vec<char> = s
        .iter()
        .flat_map(|c| fold(*c).chars().collect::<Vec<_>>())
        .collect();
    folded
        .split(|c| !word(*c))
        .filter(|s| !s.is_empty())
        .map(|s| s.iter().collect())
        .collect()
}
fn phrase_at(s: &[char], at: usize, phrase: &str) -> Option<usize> {
    let mut i = at;
    for c in phrase.chars() {
        if c == ' ' {
            let start = i;
            while i < s.len() && ws(s[i]) {
                i += 1;
            }
            if start == i {
                return None;
            }
        } else {
            let actual = *s.get(i)?;
            // Python re.IGNORECASE's extra ASCII-I and long-S matches.
            let lower = match actual {
                '\u{130}' | '\u{131}' => 'i',
                '\u{17f}' => 's',
                _ => actual.to_lowercase().next()?,
            };
            if lower != c {
                return None;
            }
            i += 1;
        }
    }
    if s.get(i).is_some_and(|c| word(*c)) {
        None
    } else {
        Some(i)
    }
}
fn groups(s: &[char]) -> Vec<[usize; 2]> {
    if s.is_empty() {
        return vec![];
    }
    let whole = || vec![[0, s.len()]];
    let positional = [
        "above",
        "below",
        "aforementioned",
        "latter",
        "former",
        "preceding",
        "following",
        "previous section",
        "previous paragraph",
        "previous item",
        "next section",
        "next paragraph",
        "next item",
    ];
    if (0..s.len()).any(|i| {
        (i == 0 || !word(s[i - 1])) && positional.iter().any(|p| phrase_at(s, i, p).is_some())
    }) {
        return whole();
    }
    let mut blocks = Vec::new();
    let mut start = None;
    let mut end = 0;
    let mut fence = None;
    for (a, b) in lines(s) {
        let content = unnewline(&s[a..b]);
        if start.is_none() && !trim(content).is_empty() {
            start = Some(a);
        }
        if let Some((ch, minimum)) = fence {
            if let Some((c, n, suffix)) = marker(content) {
                if c == ch && n >= minimum && suffix.iter().all(|c| matches!(c, ' ' | '\t')) {
                    fence = None;
                }
            }
        } else if let Some((c, n, suffix)) = marker(content) {
            if c == '`' && suffix.contains(&'`') {
                return whole();
            }
            fence = Some((c, n));
        }
        if !trim(content).is_empty() || fence.is_some() {
            end = b;
        } else if let Some(a) = start.take() {
            blocks.push([a, end]);
        }
    }
    if fence.is_some() {
        return whole();
    }
    if let Some(a) = start {
        blocks.push([a, end]);
    }
    if blocks.is_empty() {
        return whole();
    }
    let mut result: Vec<[usize; 2]> = Vec::new();
    let mut section = None;
    let mut attach = false;
    let mut prior_list = false;
    for [a, b] in blocks {
        let text = unnewline(&s[a..b]);
        let b = a + text.len();
        let first_end = text
            .iter()
            .position(|c| {
                matches!(
                    c,
                    '\n' | '\r'
                        | '\u{b}'
                        | '\u{c}'
                        | '\u{1c}'
                        | '\u{1d}'
                        | '\u{1e}'
                        | '\u{85}'
                        | '\u{2028}'
                        | '\u{2029}'
                )
            })
            .unwrap_or(text.len());
        let first = &text[..first_end];
        let stripped = trim(first);
        if [
            "unless",
            "however",
            "except",
            "only if",
            "this",
            "it",
            "they",
            "according to",
            "quoted from",
            "source",
            "attribution",
        ]
        .iter()
        .any(|p| phrase_at(stripped, 0, p).is_some())
        {
            return whole();
        }
        if [
            "user",
            "assistant",
            "system",
            "human",
            "agent",
            "question",
            "answer",
            "q",
            "a",
        ]
        .iter()
        .any(|p| {
            phrase_at(stripped, 0, p).is_some_and(|i| trim(&stripped[i..]).first() == Some(&':'))
        }) {
            return whole();
        }
        // Python (?m) uses LF only, unlike str.splitlines().
        if text.split(|c| *c == '\n').any(|line| {
            indent3(line).is_some_and(|line| {
                if !line.first().is_some_and(|c| matches!(c, '=' | '-')) {
                    return false;
                }
                let n = line.iter().take_while(|c| **c == line[0]).count();
                n >= 3 && line[n..].iter().all(|c| ws(*c))
            })
        }) {
            return whole();
        }
        let level = heading(first);
        let list = is_list(first);
        let in_section = section.is_some_and(|sl| level.map_or(true, |l| l > sl));
        let indented = first.starts_with(&[' ', ' ', ' ', ' ']) || first.starts_with(&['\t']);
        if !result.is_empty() && (attach || in_section || indented || (prior_list && list)) {
            result.last_mut().unwrap()[1] = b;
        } else {
            result.push([a, b]);
        }
        if level.is_some() && !in_section {
            section = level;
        }
        let label = trim(text);
        let label = &label[..label
            .iter()
            .rposition(|c| !matches!(c, '*' | '_'))
            .map_or(0, |i| i + 1)];
        let t = trim(text);
        attach = trim(label).last() == Some(&':')
            || (!text.contains(&'\n')
                && t.len() >= 5
                && ((t.starts_with(&['*', '*']) && t.ends_with(&['*', '*']))
                    || (t.starts_with(&['_', '_']) && t.ends_with(&['_', '_']))));
        prior_list = list;
    }
    result
}
fn render(
    s: &[char],
    groups: &[[usize; 2]],
    order: Vec<usize>,
    budget: usize,
) -> PassageViewResult {
    let mut spans = Vec::new();
    let mut chunks = Vec::new();
    for (slot, index) in order.iter().enumerate() {
        let mut parts = Vec::new();
        if slot == 0 && groups[0][0] > 0 {
            parts.push([0, groups[0][0]]);
        }
        parts.push(groups[*index]);
        let a = groups[slot][1];
        let b = groups.get(slot + 1).map_or(s.len(), |g| g[0]);
        if a < b {
            parts.push([a, b]);
        }
        chunks.push(
            parts
                .iter()
                .flat_map(|[a, b]| s[*a..*b].iter())
                .collect::<String>(),
        );
        spans.extend(parts);
    }
    let mut taken = 0;
    let mut used = 0;
    for chunk in &chunks {
        let size = chunk.len();
        if taken > 0 && size > budget.saturating_sub(used) {
            break;
        }
        used += size;
        taken += 1;
        if used > budget {
            break;
        }
    }
    PassageViewResult {
        version: VERSION.into(),
        text: chunks[..taken].concat(),
        continuation: chunks[taken..].concat(),
        full_text: chunks.concat(),
        complete: taken == chunks.len(),
        budget_honored: used <= budget,
        budget,
        returned_bytes: used,
        spans,
        group_order: order,
    }
}
pub fn build_views(
    body: &str,
    query: &str,
    budget: usize,
) -> Result<PassageViewPair, &'static str> {
    if budget == 0 {
        return Err("budget must be a positive integer UTF-8 byte count");
    }
    let s: Vec<char> = body.chars().collect();
    let groups = groups(&s);
    let terms = words(&query.chars().collect::<Vec<_>>());
    let scores: Vec<usize> = groups
        .iter()
        .map(|[a, b]| terms.intersection(&words(&s[*a..*b])).count())
        .collect();
    let mut order: Vec<usize> = (0..groups.len()).collect();
    order.sort_by_key(|i| (std::cmp::Reverse(scores[*i]), *i));
    Ok(PassageViewPair {
        plain: render(&s, &groups, (0..groups.len()).collect(), budget),
        ordered: render(&s, &groups, order, budget),
    })
}
pub fn order_reducer(body: &str, query: &str) -> String {
    build_views(body, query, usize::MAX)
        .unwrap()
        .ordered
        .full_text
}
pub fn skim(
    body: &str,
    query: &str,
    budget: usize,
    ordered: bool,
) -> Result<PassageViewResult, &'static str> {
    build_views(body, query, budget).map(|pair| if ordered { pair.ordered } else { pair.plain })
}

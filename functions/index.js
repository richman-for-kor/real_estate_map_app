const { onSchedule } = require("firebase-functions/v2/scheduler");
const { onRequest } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const axios = require("axios");
const { XMLParser } = require("fast-xml-parser");

admin.initializeApp();
const db = admin.firestore();
const parser = new XMLParser();

// 🔑 API 키 셋팅
const RAW_KEY = "bd9e1b34ac08955988ad345b55204176cbe6b780293e81e1e7f8e421cd38c9da";
const MOLIT_API_KEY = decodeURIComponent(RAW_KEY); 
const KAKAO_API_KEY = "58af62d9bd084e0ba7c2fa105414160c";

// ⏳ 과부하 방지를 위한 딜레이 함수 (밀리초 단위)
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function processRegion(lawdCd, dealYmd) {
  const molitUrl = `http://apis.data.go.kr/1613000/RTMSDataSvcAptTrade/getRTMSDataSvcAptTrade?serviceKey=${MOLIT_API_KEY}&LAWD_CD=${lawdCd}&DEAL_YMD=${dealYmd}&numOfRows=1000`;
  
  try {
    const molitRes = await axios.get(molitUrl);

    let parsedData = molitRes.data;
    if (typeof parsedData === 'string') {
        parsedData = parser.parse(parsedData);
    }
    
    if (parsedData.OpenAPI_ServiceResponse) {
        console.log(`❌ 국토부 API 에러: ${parsedData.OpenAPI_ServiceResponse.cmmMsgHeader?.errMsg}`);
        return;
    }

    let items = parsedData?.response?.body?.items?.item || parsedData?.response?.body?.items || [];
    const tradeList = Array.isArray(items) ? items : [items];

    if (tradeList.length === 0 || !tradeList[0].aptNm) {
        console.log(`⚠️ [${lawdCd}] 데이터가 비어있습니다.`);
        return;
    }

    console.log(`🎉 [${lawdCd}] 실거래가 데이터 ${tradeList.length}건 로딩 성공! 카카오 장소 매칭 시작... (잠시만 기다려주세요)`);

    const bjdMap = new Map();

    for (const trade of tradeList) {
      if (!trade.aptNm) continue;
      
      // 🔥 해결: 숫자로 들어올 수 있는 모든 값을 String()으로 안전하게 감싸줍니다!
      const aptNm = String(trade.aptNm || "").trim();
      const umdNm = String(trade.umdNm || "").trim();
      const jibun = String(trade.jibun || "").trim();
      const dealAmount = String(trade.dealAmount || "").trim();
      const dealDate = `${trade.dealYear}${String(trade.dealMonth).padStart(2, '0')}${String(trade.dealDay).padStart(2, '0')}`;
      
      const address = `${umdNm} ${jibun}`;
      
      const kakaoData = await getKakaoLocation(address, aptNm);
      
      if (!kakaoData) continue;
      const bjdCode = kakaoData.b_code;

      if (!bjdMap.has(bjdCode)) {
        bjdMap.set(bjdCode, { bjdCode, bjdName: kakaoData.address_name.split(' ').slice(0, 3).join(' '), apartments: new Map() });
      }
      
      const bjdGroup = bjdMap.get(bjdCode);

      if (!bjdGroup.apartments.has(aptNm)) {
        bjdGroup.apartments.set(aptNm, { 
          aptCode: `${bjdCode}_${jibun}`, 
          aptName_molit: aptNm, 
          kakaoName: kakaoData.place_name, 
          lat: parseFloat(kakaoData.y), 
          lng: parseFloat(kakaoData.x), 
          buildYear: trade.buildYear, 
          recentPrice: dealAmount, 
          recentDealDate: dealDate 
        });
      } else {
        const existingApt = bjdGroup.apartments.get(aptNm);
        if (parseInt(dealDate) > parseInt(existingApt.recentDealDate)) { 
          existingApt.recentPrice = dealAmount; 
          existingApt.recentDealDate = dealDate; 
        }
      }
    }

    if (bjdMap.size === 0) return;

    const batch = db.batch();
    bjdMap.forEach((bjdData, bjdCode) => {
      const docRef = db.collection("apartments_by_bjd").doc(bjdCode);
      batch.set(docRef, { 
        bjdCode: bjdData.bjdCode, 
        bjdName: bjdData.bjdName, 
        lastUpdated: new Date(), 
        apartments: Array.from(bjdData.apartments.values()) 
      }, { merge: true });
    });

    await batch.commit();
    console.log(`✅ [${lawdCd}] 지역 Firestore 저장 완벽하게 성공!`);

  } catch (error) {
    console.error(`네트워크/코드 에러:`, error.message);
  }
}

async function getKakaoLocation(address, aptNm) {
  try {
    // 1. 키워드 검색 (장소 검색)
    const keywordRes = await axios.get("https://dapi.kakao.com/v2/local/search/keyword.json", {
      headers: { Authorization: `KakaoAK ${KAKAO_API_KEY}` },
      params: { query: `${address} 아파트`, size: 5 }
    });

    const places = keywordRes.data.documents || [];
    let targetPlace = null;

    if (places.length > 0) {
      // 띄어쓰기를 무시하고 이름이 포함되어 있는지 검사 (Fuzzy Match)
      const matchedPlace = places.find(place => 
        place.place_name.replace(/\s/g, '').includes(aptNm.replace(/\s/g, '')) ||
        aptNm.replace(/\s/g, '').includes(place.place_name.replace(/\s/g, '').replace('아파트',''))
      );
      
      if (matchedPlace) {
        targetPlace = matchedPlace; // 정확히 매칭된 장소만 타겟으로 지정
      }
    }

    // 🚨 2. 이름이 일치하는 장소를 못 찾았을 경우 (엉뚱한 장소 매칭 방지)
    if (!targetPlace) {
      // 장소 대신 '주소 검색 API'를 호출하여 해당 지번의 정확한 좌표만 가져옵니다.
      const addressRes = await axios.get("https://dapi.kakao.com/v2/local/search/address.json", {
        headers: { Authorization: `KakaoAK ${KAKAO_API_KEY}` },
        params: { query: address }
      });
      
      const addresses = addressRes.data.documents || [];
      
      if (addresses.length > 0) {
        const addrDoc = addresses[0];
        return {
          place_name: aptNm, // 🌟 카카오 장소명이 없으므로 국토부 원래 아파트명을 그대로 사용
          x: addrDoc.x,
          y: addrDoc.y,
          b_code: addrDoc.address ? addrDoc.address.b_code : null,
          address_name: addrDoc.address_name
        };
      } else {
        // 주소조차 검색되지 않으면 매칭 포기
        return null;
      }
    }

    // 3. 키워드 검색으로 찾은 경우, 법정동 코드를 얻기 위해 행정구역 API 호출
    const coordRes = await axios.get("https://dapi.kakao.com/v2/local/geo/coord2regioncode.json", {
        headers: { Authorization: `KakaoAK ${KAKAO_API_KEY}` },
        params: { x: targetPlace.x, y: targetPlace.y }
    });
    
    const regionDoc = coordRes.data.documents.find(doc => doc.region_type === 'B');
    
    return {
      place_name: targetPlace.place_name,
      x: targetPlace.x,
      y: targetPlace.y,
      b_code: regionDoc?.code || null,
      address_name: regionDoc?.address_name || null
    };

  } catch (error) {
    console.error(`카카오 API 호출 에러 (${address}):`, error.message);
    return null;
  }
}

// ============================================================================
// 🌟 [자동화 V4 단계] 전국 아파트 기본+상세 정보 자동 연속 수집 (Auto Paging)
// ============================================================================

// 웹 브라우저 접속 시, 응답은 바로 보내고 서버 백그라운드에서 자동 수집을 시작합니다.
exports.testTotalDetails = onRequest(
  { timeoutSeconds: 1800, memory: "1GiB" },
  async (req, res) => {
    try {
      res.send(`<h1>✅ 11페이지부터 마스터 데이터 자동 수집 시작! 터미널(Vscode) 로그를 확인하세요.</h1>`);
      
      let pageNo = 11; // 🔥 여기서부터 시작! (10페이지까지 하셨으니 11로 세팅)
      let hasNextPage = true;

      while (hasNextPage) {
        console.log(`\n======================================================`);
        console.log(`🚀 [마스터 상세정보 V4] ${pageNo}페이지 (500건) 자동 수집 시작...`);
        console.log(`======================================================\n`);
        
        // 함수가 끝날 때까지 기다리고, 결과(true/false)를 받습니다.
        hasNextPage = await runTotalDetailBatch(pageNo);
        
        // 데이터가 있어서 true를 반환했다면, 다음 페이지로 넘어가기 전 10초 대기!
        if (hasNextPage) {
            console.log(`⏳ [${pageNo}페이지 완료] 국토부/카카오 API 과부하 방지를 위해 10초간 대기합니다...`);
            await delay(10000); // 🔥 10초(10000ms) 딜레이
            pageNo++; // 다음 페이지 번호로 증가
        }
      }
      
      console.log(`🎉 더 이상 조회되는 데이터가 없습니다! 전국 아파트 마스터 데이터 자동 수집 완벽 종료!`);
    } catch (error) {
      console.error(error);
    }
  }
);

// 반환값이 true(다음 페이지 계속) 또는 false(종료) 인 함수로 구조 변경
async function runTotalDetailBatch(pageNo) {
  // 🔥 numOfRows를 500으로 변경!
  const listUrl = `http://apis.data.go.kr/1613000/AptListService3/getTotalAptList3?serviceKey=${MOLIT_API_KEY}&pageNo=${pageNo}&numOfRows=500`;
  
  try {
    const listRes = await axios.get(listUrl);
    let parsedList = typeof listRes.data === 'string' ? parser.parse(listRes.data) : listRes.data;
    
    let items = parsedList?.response?.body?.items?.item || parsedList?.response?.body?.items || [];
    const aptList = Array.isArray(items) ? items : [items];
    
    // 🔥 종료 조건: 데이터가 더 이상 없으면 false를 반환하여 루프를 멈춥니다.
    if (aptList.length === 0 || !aptList[0]?.kaptCode) {
      console.log(`⚠️ [${pageNo}페이지] 더 이상 조회되는 데이터가 없습니다.`);
      return false; 
    }

    console.log(`📍 [${pageNo}페이지] 총 ${aptList.length}개 단지 획득! V4 데이터 수집 시작...`);

    let matchedCount = 0;
    const batch = db.batch(); 

    for (let i = 0; i < aptList.length; i++) {
      const apt = aptList[i];
      const kaptCode = apt.kaptCode;
      const kaptName = String(apt.kaptName || "").trim();
      let bjdCode = String(apt.bjdCode || ""); 

      const bassUrl = `http://apis.data.go.kr/1613000/AptBasisInfoServiceV4/getAphusBassInfoV4?serviceKey=${MOLIT_API_KEY}&kaptCode=${kaptCode}`;
      const dtlUrl = `http://apis.data.go.kr/1613000/AptBasisInfoServiceV4/getAphusDtlInfoV4?serviceKey=${MOLIT_API_KEY}&kaptCode=${kaptCode}`;
      
      try {
        const [bassRes, dtlRes] = await Promise.all([
            axios.get(bassUrl).catch(() => ({ data: {} })),
            axios.get(dtlUrl).catch(() => ({ data: {} }))
        ]);

        let parsedBass = typeof bassRes.data === 'string' ? parser.parse(bassRes.data) : bassRes.data;
        let parsedDtl = typeof dtlRes.data === 'string' ? parser.parse(dtlRes.data) : dtlRes.data;
        
        const bassBody = parsedBass?.response?.body || {};
        const dtlBody = parsedDtl?.response?.body || {};
        
        const bassItem = bassBody.item || bassBody.items?.item || bassBody.items || {};
        const dtlItem = dtlBody.item || dtlBody.items?.item || dtlBody.items || {};

        const jibunAddress = String(bassItem.bjdJuso || bassItem.kaptAddr || "").trim();
        const roadAddress = String(bassItem.doroJuso || "").trim();

        if (!jibunAddress && !roadAddress) continue; 

        const searchAddress = roadAddress || jibunAddress; 
        let kakaoName = kaptName;
        let lat = 0.0, lng = 0.0;

        if (searchAddress) {
          const kakaoData = await getKakaoLocation(searchAddress, kaptName);
          if (kakaoData) {
            kakaoName = kakaoData.place_name || kaptName;
            lat = parseFloat(kakaoData.y) || 0.0;
            lng = parseFloat(kakaoData.x) || 0.0;
            if (kakaoData.b_code) bjdCode = kakaoData.b_code; 
          }
        }

        const totalHouseholds = parseInt(bassItem.kaptdaCnt || "0");
        const parkUp = parseInt(dtlItem.kaptdPcnt || "0");
        const parkDown = parseInt(dtlItem.kaptdPcntu || "0");
        const totalParking = parkUp + parkDown;
        const parkingPerHousehold = totalHouseholds > 0 ? (totalParking / totalHouseholds).toFixed(2) : "0.00";
        
        const areaInfo = {
            "under60": parseInt(bassItem.kaptMparea60 || "0"),
            "under85": parseInt(bassItem.kaptMparea85 || "0"),
            "under135": parseInt(bassItem.kaptMparea135 || "0"),
            "over136": parseInt(bassItem.kaptMparea136 || "0"),
        };

        const docRef = db.collection("apartment_details").doc(kaptCode);
        batch.set(docRef, {
            kaptCode: kaptCode,
            bjdCode: bjdCode,
            complexName: kaptName,
            kakaoName: kakaoName,
            lat: lat,
            lng: lng,
            jibunAddress: jibunAddress,
            roadAddress: roadAddress,
            approvalDate: String(bassItem.kaptUsedate || ""),
            buildYear: parseInt(String(bassItem.kaptUsedate || "0").substring(0, 4)),
            totalHouseholds: totalHouseholds,
            dongCount: parseInt(bassItem.kaptDongCnt || "0"),
            lowestFloor: parseInt(bassItem.kaptBaseFloor || "0"),
            highestFloor: parseInt(bassItem.kaptTopFloor || "0"),
            heatingMethod: bassItem.codeHeatNm || "정보없음",
            corridorType: bassItem.codeHallNm || "정보없음",
            developer: bassItem.kaptBcompany || bassItem.kaptAcompany || "정보없음",
            managementMethod: bassItem.codeMgrNm || "정보없음",
            parkingCount: totalParking,
            parkingPerHousehold: parseFloat(parkingPerHousehold),
            facilities: dtlItem.welfareFacility || "",
            busStopDistance: dtlItem.kaptdWtimebus || "",
            subwayLine: dtlItem.subwayLine || "",
            subwayStation: dtlItem.subwayStation || "",
            subwayDistance: dtlItem.kaptdWtimesub || "",
            convenienceFacilities: dtlItem.convenientFacility || "",
            educationalFacilities: dtlItem.educationFacility || "",
            areaInfo: areaInfo,
            lastUpdated: new Date()
        }, { merge: true });
        
        matchedCount++;
        
        if (matchedCount % 50 === 0) {
            console.log(`   ⏳ [${pageNo}페이지] ${matchedCount}/500개 처리 완료...`);
        }

      } catch (err) {
        // 무시하고 다음 단지로
      }
      
      await delay(800); // 디도스 방지 0.8초
    }

    await batch.commit();
    console.log(`✅ [${pageNo}페이지] ${matchedCount}개 단지 데이터 DB 저장 완벽하게 성공!`);
    return true; // 🔥 무사히 끝났으니 다음 페이지로 가라는 신호 반환

  } catch (error) {
    console.error(`❌ [${pageNo}페이지] API 응답 에러 (500 에러 등):`, error.message);
    console.log("⚠️ 국토부 서버 에러로 인해 자동 수집을 일시 중단합니다. 1~2분 뒤 다시 접속하여 마저 진행하세요.");
    return false; // 서버가 터졌을 때 무한루프 도는 걸 막기 위해 정지
  }
}


// ============================================================================
// 🌟 [통합 3단계] 10년 치 실거래가 수집 & 지도 마커 최신가 동시 업데이트!
// ============================================================================

// 카카오 API를 대체할 인메모리(In-memory) 법정동 캐시 (마커 데이터 통째로 보관)
let bjdDocCache = null;

async function loadBjdCache() {
    if (bjdDocCache) return;
    bjdDocCache = new Map();
    const bjdSnapshot = await db.collection("apartments_by_bjd").get();
    
    for (const doc of bjdSnapshot.docs) {
        const data = doc.data();
        const bjdCode = doc.id;
        const lawdCd = bjdCode.substring(0, 5); 
        const umdNm = data.bjdName.split(' ').pop(); 
        
        bjdDocCache.set(`${lawdCd}_${umdNm}`, {
            bjdCode: bjdCode,
            data: data, // 마커 배열(apartments)이 포함된 전체 데이터
            isModified: false // 이번 달 거래로 '최신 가격'이 갱신되었는지 체크
        });
    }
    console.log(`✅ 법정동 로컬 캐시 로드 완료: ${bjdDocCache.size}개 동 매핑 (마커 연동 완료)`);
}

// (testBackfillTrades 함수는 그대로 두시면 됩니다!)

async function runBackfillBatch(ymd) {
    console.log(`🚀 [통합 실거래가] ${ymd}월 전국 데이터 수집 (차트 & 마커 동시 병합)...`);
    await loadBjdCache();

    // 전국 시군구 코드 250개
    const allLawdCodes = [
        "11110","11140","11170","11200","11215","11230","11260","11290","11305","11320","11350","11380","11410","11440","11470","11500","11530","11545","11560","11590","11620","11650","11680","11710","11740",
        "26110","26140","26170","26200","26230","26260","26290","26320","26350","26380","26410","26440","26470","26500","26530","26710","27110","27140","27170","27200","27230","27260","27290","27710","28110","28140","28170","28177","28185","28200","28237","28245","28260","28710","28720","29110","29140","29155","29170","29200","30110","30140","30170","30200","30230","31110","31140","31170","31200","31710","36110","41111","41113","41115","41117","41131","41133","41135","41150","41171","41173","41190","41210","41220","41250","41271","41273","41281","41285","41287","41290","41310","41360","41370","41390","41410","41430","41450","41461","41463","41465","41480","41500","41550","41570","41590","41610","41630","41650","41670","41800","41820","41830","42110","42130","42150","42170","42190","42210","42230","42720","42730","42750","42760","42770","42780","42790","42800","42810","42820","42830","43111","43112","43113","43114","43130","43150","43720","43730","43740","43745","43750","43760","43770","43800","44131","44133","44150","44180","44200","44210","44230","44250","44270","44710","44730","44760","44770","44790","44800","44810","44825","45111","45113","45130","45140","45180","45210","45710","45720","45730","45740","45750","45770","45790","45800","46110","46130","46150","46170","46230","46710","46720","46730","46770","46780","46790","46800","46810","46820","46830","46840","46860","46870","46880","46890","46900","46910","47111","47113","47130","47150","47170","47190","47210","47230","47250","47280","47290","47720","47730","47750","47760","47770","47820","47830","47840","47850","47900","47920","47930","47940","48121","48123","48125","48127","48129","48170","48220","48240","48250","48270","48310","48330","48720","48730","48740","48820","48840","48850","48860","48870","48880","48890","50110","50130"
    ];

    for (let i = 0; i < allLawdCodes.length; i++) {
        const lawdCd = allLawdCodes[i];
        const molitUrl = `http://apis.data.go.kr/1613000/RTMSDataSvcAptTrade/getRTMSDataSvcAptTrade?serviceKey=${MOLIT_API_KEY}&LAWD_CD=${lawdCd}&DEAL_YMD=${ymd}&numOfRows=10000`;

        try {
            const molitRes = await axios.get(molitUrl);
            let parsedData = typeof molitRes.data === 'string' ? parser.parse(molitRes.data) : molitRes.data;

            if (parsedData.OpenAPI_ServiceResponse) continue;

            const bodyItem = parsedData?.response?.body?.items?.item || parsedData?.response?.body?.items || [];
            const tradeList = Array.isArray(bodyItem) ? bodyItem : [bodyItem];

            if (tradeList.length === 0 || !tradeList[0].aptNm) continue;

            const tradesByApt = new Map();

            // 🔥 1. 데이터 분류 및 마커 최신 가격 업데이트
            for (const trade of tradeList) {
                if (!trade.aptNm) continue;
                
                const umdNm = String(trade.umdNm || "").trim();
                const jibun = String(trade.jibun || "").trim();
                
                // 캐시에서 해당 동네 정보 가져오기
                const cacheItem = bjdDocCache.get(`${lawdCd}_${umdNm}`);
                if (!cacheItem) continue; 

                const bjdCode = cacheItem.bjdCode;
                const aptCode = `${bjdCode}_${jibun}`;
                
                // [차트용 데이터 세팅]
                const area = parseFloat(trade.excluUseAr || "0");
                const supplyArea = area * 1.33; 
                const pyeong = Math.round(supplyArea / 3.3058); 
                const areaKey = `${pyeong}평`; 
                
                const priceStr = String(trade.dealAmount || "").trim().replace(/,/g, '');
                const price = parseInt(priceStr || "0");
                const floor = parseInt(trade.floor || "0");
                const dealDate = `${trade.dealYear}${String(trade.dealMonth).padStart(2, '0')}${String(trade.dealDay).padStart(2, '0')}`;

                if (!tradesByApt.has(aptCode)) tradesByApt.set(aptCode, {});
                const aptTrades = tradesByApt.get(aptCode);
                if (!aptTrades[areaKey]) aptTrades[areaKey] = [];

                aptTrades[areaKey].push({ date: dealDate, price: price, floor: floor, netArea: area });

                // 🌟 [핵심] 지도 마커용 최신 실거래가 동시 업데이트!
                const aptArray = cacheItem.data.apartments || [];
                const aptIndex = aptArray.findIndex(a => a.aptCode === aptCode);
                
                if (aptIndex !== -1) {
                    const existingDate = aptArray[aptIndex].recentDealDate || "0";
                    // 지금 가져온 거래가 기존에 저장된 거래일자보다 최신이거나 같으면 마커 가격 교체!
                    if (parseInt(dealDate) >= parseInt(existingDate)) {
                        aptArray[aptIndex].recentPrice = priceStr;
                        aptArray[aptIndex].recentDealDate = dealDate;
                        cacheItem.isModified = true; // DB 업데이트 대상(장바구니)에 담기
                    }
                }
            }

            if (tradesByApt.size === 0) continue;

            // 🔥 2. 차트용 데이터(apartment_trades) Firestore 저장
            const aptCodes = Array.from(tradesByApt.keys());
            const chunks = [];
            for (let k = 0; k < aptCodes.length; k += 100) chunks.push(aptCodes.slice(k, k + 100));

            let savedAptCount = 0;

            for (const chunk of chunks) {
                const docRefs = chunk.map(code => db.collection("apartment_trades").doc(code));
                const snapshots = await db.getAll(...docRefs);
                const batch = db.batch();

                snapshots.forEach((snap, idx) => {
                    const aptCode = chunk[idx];
                    const newTrades = tradesByApt.get(aptCode); 
                    const existingData = snap.exists ? snap.data() : { aptCode: aptCode, tradesByArea: {} };
                    const existingTrades = existingData.tradesByArea || {};

                    for (const [areaKey, tradeArr] of Object.entries(newTrades)) {
                        if (!existingTrades[areaKey]) existingTrades[areaKey] = [];

                        const existingDates = new Set(existingTrades[areaKey].map(t => t.date + "_" + t.price));
                        for (const t of tradeArr) {
                            if (!existingDates.has(t.date + "_" + t.price)) {
                                existingTrades[areaKey].push(t);
                            }
                        }
                        existingTrades[areaKey].sort((a, b) => parseInt(a.date) - parseInt(b.date));
                    }

                    batch.set(docRefs[idx], {
                        aptCode: aptCode,
                        tradesByArea: existingTrades,
                        lastUpdated: new Date()
                    }, { merge: true });

                    savedAptCount++;
                });

                await batch.commit();
            }

            // 🔥 3. 마커 데이터(apartments_by_bjd) Firestore 덮어쓰기
            const bjdBatch = db.batch();
            let bjdUpdateCount = 0;
            
            // 캐시를 돌면서 가격이 갱신된 동네만 찾아서 한 번에 업데이트!
            bjdDocCache.forEach((cacheItem) => {
                if (cacheItem.isModified) {
                    const docRef = db.collection("apartments_by_bjd").doc(cacheItem.bjdCode);
                    bjdBatch.update(docRef, { apartments: cacheItem.data.apartments });
                    cacheItem.isModified = false; // 완료 후 플래그 초기화
                    bjdUpdateCount++;
                }
            });

            if (bjdUpdateCount > 0) {
                await bjdBatch.commit();
            }

            console.log(`✅ [${lawdCd}] 차트(${savedAptCount}단지) & 마커(${bjdUpdateCount}개동) 통합 저장 완료!`);

        } catch(e) {
            console.error(`❌ [${lawdCd}] 에러:`, e.message);
        }

        await delay(1500); 
    }
    console.log(`🎉 ${ymd}월 실거래가 통합 백필 & 마커 업데이트 배치가 완벽하게 끝났습니다!`);
}


// ============================================================================
// 🌟 [자동화] 매일 새벽 2시 최신 실거래가 차트 데이터 자동 병합 (스케줄러)
// ============================================================================

exports.updateDailyTrades = onSchedule(
  { 
    schedule: "0 2 * * *", // 매일 새벽 2시
    timeZone: "Asia/Seoul", 
    timeoutSeconds: 1800,  // 최대 1시간 허용
    memory: "1GiB" 
  },
  async (event) => {
    try {
      console.log("⏰ [새벽 2시 자동실행] 최신 실거래가 차트 데이터 업데이트 시작...");

      const today = new Date();
      
      // 1. 이번 달 YYYYMM 구하기 (예: 202603)
      const currentMonth = `${today.getFullYear()}${String(today.getMonth() + 1).padStart(2, "0")}`;
      
      // 2. 지난달 YYYYMM 구하기 (예: 202602 - 실거래가 지연 신고 대비)
      const prevDate = new Date(today.getFullYear(), today.getMonth() - 1, 1);
      const prevMonth = `${prevDate.getFullYear()}${String(prevDate.getMonth() + 1).padStart(2, "0")}`;

      console.log(`📍 업데이트 대상 월: 지난달(${prevMonth}), 이번달(${currentMonth})`);

      // 3. 만들어둔 runBackfillBatch 함수를 재활용하여 두 달 치 데이터를 차례대로 수집 및 병합!
      await runBackfillBatch(prevMonth);
      
      // 서버 무리 가지 않게 10초 쉬고 이번 달 데이터 진행
      await delay(10000); 
      
      await runBackfillBatch(currentMonth);

      console.log("✅ 매일 새벽 2시 최신 실거래가 업데이트 작업이 완벽하게 완료되었습니다!");
    } catch (error) {
      console.error("❌ 새벽 2시 실거래가 업데이트 스케줄러 에러:", error);
    }
  }
);
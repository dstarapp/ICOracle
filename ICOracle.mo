/**
 * Module     : ICOracle.mo
 * Author     : ICOracle Team
 * Stability  : Experimental
 * Description: Decentralized oracle network on IC blockchain.
 * Refers     : https://github.com/eleven-cat/ICOracle
 */

import Buffer "mo:base/Buffer";
import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Hash "mo:base/Hash";
import Int "mo:base/Int";
import Int64 "mo:base/Int64";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Char "mo:base/Char";
import Nat "mo:base/Nat";
import Nat32 "mo:base/Nat32";
import Nat64 "mo:base/Nat64";
import Float "mo:base/Float";
import Option "mo:base/Option";
import Principal "mo:base/Principal";
import Cycles "mo:base/ExperimentalCycles";
import Text "mo:base/Text";
import T "./lib/ICOracle";
import Time "mo:base/Time";
import Debug "mo:base/Debug";
import Error "mo:base/Error";
import Trie "./lib/Trie";
import Tools "./lib/ICLighthouse/Tools";
import Minting "./lib/CyclesMinting";
import ICHTTP "./lib/ICHTTP";
import DRC207 "./lib/ICLighthouse/DRC207";
import IC "./lib/IC";
import ICSRouter "./lib/ICLighthouse/ICSwapRouter";
import ICSwap "./lib/ICLighthouse/ICSwap";
import ICDex "./lib/ICLighthouse/ICDexTypes";
import Sonic "./lib/Sonic/Sonic";
import ICPSwap "./lib/ICPSwap/ICPSwap";
// import CertifiedData "mo:base/CertifiedData";

shared (installMsg) actor class ICOracle() = this {
    type Provider = T.Provider;
    type SeriesId = T.SeriesId;
    type HeartbeatId = T.HeartbeatId; // interval: [start, end)
    type Timestamp = T.Timestamp; // seconds
    type SeriesInfo = T.SeriesInfo;
    type DataItem = T.DataItem;
    type RequestLog = T.RequestLog;
    type Log = T.Log;
    type DataResponse = T.DataResponse;
    type SeriesDataResponse = T.SeriesDataResponse;
    type VolatilityResponse = T.VolatilityResponse;

    // Variables
    private let version_ : Text = "0.5";
    private let name_ : Text = "ICOracle";
    private let tokenCanister = "imeri-bqaaa-aaaai-qnpla-cai"; // $OT
    private let icswapRouter = "j4d4d-pqaaa-aaaak-aanxq-cai";
    private let icdexRouter = "ltyfs-qiaaa-aaaak-aan3a-cai";
    private let sonicRouter = "3xwpq-ziaaa-aaaah-qcn4a-cai";
    private let MAX_RESPONSE_BYTES = 2 * 1024 * 1024;
    private stable var setting_apilayer : T.OutCallAPI = {
        name = "";
        host = "";
        url = "";
        key = "";
    };
    private stable var setting_binance : T.OutCallAPI = {
        name = "";
        host = "";
        url = "";
        key = "";
    };
    private stable var setting_coinmarketcap : T.OutCallAPI = {
        name = "";
        host = "";
        url = "";
        key = "";
    };
    private stable var setting_coinbase : T.OutCallAPI = {
        name = "";
        host = "";
        url = "";
        key = "";
    };
    private stable var fee : Nat = 0; //  100000000 OT
    private stable var owner : Principal = installMsg.caller;
    private stable var providers = List.nil<(Provider, [SeriesId], [Principal])>();
    private stable var workloads : Trie.Trie<Provider, (score : Nat, invalid : Nat)> = Trie.empty();
    private stable var index : Nat = 3;
    private stable var seriesInfo : Trie.Trie<SeriesId, (SeriesInfo, Timestamp)> = Trie.empty();
    private stable var seriesData : Trie.Trie2D<SeriesId, HeartbeatId, DataItem> = Trie.empty();
    private stable var requestLogs : Trie.Trie2D<SeriesId, HeartbeatId, Log> = Trie.empty();
    private stable var seriesDataRapid : Trie.Trie2D<SeriesId, HeartbeatId, DataItem> = Trie.empty(); // TODO
    private stable var requestLogsRapid : Trie.Trie2D<SeriesId, HeartbeatId, Log> = Trie.empty(); // TODO
    private stable var dexs : Trie.Trie<Text, Principal> = Trie.empty();

    // query from trie
    private func triePage<V>(_trie : Trie.Trie<Nat, V>, _start : Nat, _page : Nat, _period : Nat) : [(Nat, V)] {
        if (_page < 1 or _period < 1) {
            return [];
        };
        let offset = Nat.sub(_page, 1) * _period;
        if (offset >= _start) {
            return [];
        };
        let start = Nat.sub(_start, offset);
        var end : Nat = 0;
        if (start > _period) {
            end := Nat.sub(start, _period);
        };
        let trie = Trie.filter<Nat, V>(_trie, func(k : Nat, v : V) : Bool { k >= end and k <= start });
        return Iter.toArray(Trie.iter(trie));
        // let arr = Array.filter(Iter.toArray(Trie.iter(_trie)), func (t:(Nat,V)): Bool{ t.0 >= end and t.0 <= start; });
        // return arr;
    };
    private func _natToFloat(_n : Nat) : Float {
        return Float.fromInt64(Int64.fromNat64(Nat64.fromNat(_n)));
    };
    private func keyb(t : Blob) : Trie.Key<Blob> {
        return { key = t; hash = Blob.hash(t) };
    };
    private func keyp(t : Principal) : Trie.Key<Principal> {
        return { key = t; hash = Principal.hash(t) };
    };
    private func keyn(t : Nat) : Trie.Key<Nat> {
        return { key = t; hash = Tools.natHash(t) };
    };
    private func keyt(t : Text) : Trie.Key<Text> {
        return { key = t; hash = Text.hash(t) };
    };

    private func _now() : Timestamp {
        return Int.abs(Time.now() / 1000000000);
    };
    private func _onlyOwner(_caller : Principal) : Bool {
        return _caller == owner;
    };
    private func _onlyProvider(_caller : Provider, _sid : SeriesId) : Bool {
        if (_caller == Principal.fromActor(this)) { return true };
        return Option.isSome(
            List.find(
                providers,
                func(t : (Provider, [SeriesId], [Principal])) : Bool {
                    (_caller == t.0 or Option.isSome(Array.find(t.2, func(s : Principal) : Bool { _caller == s }))) and Option.isSome(Array.find(t.1, func(s : SeriesId) : Bool { _sid == s or s == 0 }));
                },
            ),
        );
    };
    private func _onlyAnon(_caller : Principal) : Bool {
        return Tools.principalForm(_caller) == #AnonymousId;
    };
    private func _isCanister(_caller : Principal) : Bool {
        return Tools.principalForm(_caller) == #OpaqueId;
    };
    private func _getProvider(_caller : Principal) : Provider {
        switch (
            List.find(
                providers,
                func(t : (Provider, [SeriesId], [Principal])) : Bool {
                    _caller == t.0 or Option.isSome(Array.find(t.2, func(s : Principal) : Bool { _caller == s }));
                },
            ),
        ) {
            case (?(item)) { return item.0 };
            case (_) { assert (false) };
        };
        return Principal.fromActor(this);
    };

    private func _clearCache(_sid : SeriesId) : () {
        var info : SeriesInfo = _getSeriesInfo(_sid);
        if (info.heartbeat == 0) {
            return ();
        };
        switch (Trie.get(seriesData, keyn(_sid), Nat.equal)) {
            case (?(trie)) {
                let temp = Trie.filter(trie, func(k : HeartbeatId, v : DataItem) : Bool { _now() < k * info.heartbeat + info.cacheDuration });
                seriesData := Trie.put(seriesData, keyn(_sid), Nat.equal, temp).0;
            };
            case (_) {};
        };
        switch (Trie.get(requestLogs, keyn(_sid), Nat.equal)) {
            case (?(trie)) {
                let temp = Trie.filter(trie, func(k : HeartbeatId, v : Log) : Bool { _now() < k * info.heartbeat + info.conDuration });
                requestLogs := Trie.put(requestLogs, keyn(_sid), Nat.equal, temp).0;
            };
            case (_) {};
        };
    };
    private func _chargeFee(_account : Principal, _num : Nat) : () {
        // TODO
        // free for whiltelist
        // balance[_account] - _num*fee;
    };
    private func _categoryCheck(_cat : T.Category, _sid : Nat) : Bool {
        switch (_cat) {
            case (#Crypto) { _sid >= 0 and _sid <= 999 };
            case (#Currency) { _sid >= 1000 and _sid <= 1999 };
            case (#Commodity) { _sid >= 2000 and _sid <= 2999 };
            case (#Stock) { _sid >= 3000 and _sid <= 9999 };
            case (#Economy) { _sid >= 10000 and _sid <= 19999 };
            case (#Weather) { _sid >= 20000 and _sid <= 29999 };
            case (#Other) { _sid >= 30000 and _sid <= 99999 };
            case (#Sports) { _sid >= 100000 and _sid <= 999999 };
            case (#Social) { _sid >= 1000000 and _sid <= 9999999 };
        };
    };
    private func _getSeries(_sid : SeriesId, _page : Nat, _periodSeconds : Nat) : [(Timestamp, Nat)] {
        var info : SeriesInfo = _getSeriesInfo(_sid);
        if (info.heartbeat == 0) {
            return [];
        };
        var start : Nat = _now() / info.heartbeat;
        var period = _periodSeconds / info.heartbeat + 1;
        switch (Trie.get(seriesData, keyn(_sid), Nat.equal)) {
            case (?(trie)) {
                return Array.map<(HeartbeatId, DataItem), (Timestamp, Nat)>(
                    triePage<DataItem>(trie, start, _page, period),
                    func(t : (HeartbeatId, DataItem)) : (Timestamp, Nat) {
                        (t.1.timestamp, t.1.value);
                    },
                );
            };
            case (_) {
                return [];
            };
        };
    };
    private func _getDataItem(_sid : SeriesId, _ts : Timestamp) : ?(Timestamp, Nat) {
        var info : SeriesInfo = _getSeriesInfo(_sid);
        if (info.heartbeat == 0) {
            return null;
        };
        var pid = _ts / info.heartbeat;
        switch (Trie.get(seriesData, keyn(_sid), Nat.equal)) {
            case (?(trie)) {
                while (pid >= _getSeriesCreationTime(_sid) / info.heartbeat) {
                    switch (Trie.get(trie, keyn(pid), Nat.equal)) {
                        case (?(v)) { return ?(v.timestamp, v.value) };
                        case (_) {
                            pid -= 1;
                        };
                    };
                };
                return null;
            };
            case (_) {
                return null;
            };
        };
    };
    private func _setDataItem(_sid : SeriesId, _pid : HeartbeatId, _value : DataItem) : () {
        seriesData := Trie.put2D(seriesData, keyn(_sid), Nat.equal, keyn(_pid), Nat.equal, _value);
        _clearCache(_sid);
    };
    private func _getLog(_sid : SeriesId, _pid : HeartbeatId) : ?Log {
        switch (Trie.get(requestLogs, keyn(_sid), Nat.equal)) {
            case (?(trie)) {
                switch (Trie.get(trie, keyn(_pid), Nat.equal)) {
                    case (?(v)) {
                        return ?v;
                    };
                    case (_) {
                        return null;
                    };
                };
            };
            case (_) {
                return null;
            };
        };
    };
    private func _requestData(_sid : SeriesId, _pid : HeartbeatId, _item : RequestLog) : () {
        switch (_getLog(_sid, _pid)) {
            case (?(log)) {
                requestLogs := Trie.put2D(
                    requestLogs,
                    keyn(_sid),
                    Nat.equal,
                    keyn(_pid),
                    Nat.equal,
                    {
                        confirmed = log.confirmed;
                        requestLogs = Tools.arrayAppend(log.requestLogs, [_item]);
                    },
                );
            };
            case (_) {
                requestLogs := Trie.put2D(
                    requestLogs,
                    keyn(_sid),
                    Nat.equal,
                    keyn(_pid),
                    Nat.equal,
                    {
                        confirmed = false;
                        requestLogs = [_item];
                    },
                );
            };
        };
        _clearCache(_sid);
    };
    private func _confirmData(_sid : SeriesId, _pid : HeartbeatId) : () {
        switch (_getLog(_sid, _pid)) {
            case (?(log)) {
                requestLogs := Trie.put2D(
                    requestLogs,
                    keyn(_sid),
                    Nat.equal,
                    keyn(_pid),
                    Nat.equal,
                    {
                        confirmed = true;
                        requestLogs = log.requestLogs;
                    },
                );
            };
            case (_) {};
        };
    };
    private func _setWorkload(_account : Principal, _score : ?Nat, _invalid : ?Nat) : () {
        switch (Trie.get(workloads, keyp(_account), Principal.equal)) {
            case (?(work)) {
                let score = work.0 + Option.get(_score, 0);
                let invalid = work.1 + Option.get(_invalid, 0);
                workloads := Trie.put(workloads, keyp(_account), Principal.equal, (score, invalid)).0;
            };
            case (_) {
                let score = Option.get(_score, 0);
                let invalid = Option.get(_invalid, 0);
                workloads := Trie.put(workloads, keyp(_account), Principal.equal, (score, invalid)).0;
            };
        };
    };
    private func _getSeriesInfo(_sid : SeriesId) : SeriesInfo {
        var info : SeriesInfo = {
            name = "";
            base = "";
            quote = "";
            decimals = 0;
            heartbeat = 0; // seconds
            conMaxDevRate = 0; // ‱ permyriad
            conMinRequired = 0;
            conDuration = 0;
            cacheDuration = 0;
            sourceType = #HybridOracle;
            sourceName = "";
        };
        switch (Trie.get(seriesInfo, keyn(_sid), Nat.equal)) {
            case (?(item)) { return item.0 };
            case (_) { assert (false); return info };
        };
    };
    private func _getSeriesCreationTime(_sid : SeriesId) : Nat {
        switch (Trie.get(seriesInfo, keyn(_sid), Nat.equal)) {
            case (?(item)) { return item.1 };
            case (_) { return 0 };
        };
    };

    private func _setData(_account : Principal, _sid : SeriesId, _request : RequestLog) : (confirmed : Bool) {
        var info : SeriesInfo = _getSeriesInfo(_sid);
        if (info.heartbeat == 0) {
            assert (false);
        };
        let pid = _request.request.timestamp / info.heartbeat;
        //check
        assert (_now() < _request.request.timestamp + info.conDuration);
        _setWorkload(_account, ?1, null);
        var puted : Bool = false;
        switch (_getLog(_sid, pid)) {
            case (?(log)) {
                if (Option.isSome(Array.find(log.requestLogs, func(t : RequestLog) : Bool { t.provider == _request.provider }))) {
                    puted := true;
                };
                if (log.confirmed) { return true };
            };
            case (_) {};
        };
        //put
        if (not (puted)) {
            _requestData(_sid, pid, _request);
        };
        //cons
        return _consensus(_sid, pid);
    };
    private func _consensus(_sid : SeriesId, _pid : HeartbeatId) : (confirmed : Bool) {
        var info : SeriesInfo = _getSeriesInfo(_sid);
        if (info.heartbeat == 0) {
            assert (false);
        };
        switch (_getLog(_sid, _pid)) {
            case (?(log)) {
                if (log.confirmed) { return true } else {
                    var count : Nat = 0;
                    var sum : Nat = 0;
                    for (request in log.requestLogs.vals()) {
                        count += 1;
                        sum += request.request.value;
                    };
                    var avg = sum / count;
                    var confirmed : Nat = 0;
                    var newSum : Nat = 0;
                    for (request in log.requestLogs.vals()) {
                        if (request.request.value >= avg and Nat.sub(request.request.value, avg) * 10000 / avg <= info.conMaxDevRate) {
                            confirmed += 1;
                            newSum += request.request.value;
                        } else if (request.request.value < avg and Nat.sub(avg, request.request.value) * 10000 / avg <= info.conMaxDevRate) {
                            confirmed += 1;
                            newSum += request.request.value;
                        };
                    };
                    if (confirmed >= info.conMinRequired) {
                        _confirmData(_sid, _pid);
                        _setDataItem(_sid, _pid, { timestamp = _now(); value = newSum / confirmed });
                        for (request in log.requestLogs.vals()) {
                            if (request.request.value >= avg and Nat.sub(request.request.value, avg) * 10000 / avg <= info.conMaxDevRate) {
                                _setWorkload(request.provider, ?1, null);
                            } else if (request.request.value < avg and Nat.sub(avg, request.request.value) * 10000 / avg <= info.conMaxDevRate) {
                                _setWorkload(request.provider, ?1, null);
                            } else {
                                _setWorkload(request.provider, null, ?1);
                            };
                        };
                        return true;
                    } else {
                        return false;
                    };
                };
            };
            case (_) { return false };
        };
    };
    // auto request
    private func _requestFromICSwap(_sid : SeriesId, _pair : Principal, _reverse : Bool) : async () {
        let dex : ICSwap.Self = actor (Principal.toText(_pair));
        let provider = Principal.fromActor(this);
        let liquid = await dex.liquidity(null);
        switch (Trie.get(seriesInfo, keyn(_sid), Nat.equal)) {
            case (?(item)) {
                let decimals = item.0.decimals;
                var conversionRate : Nat = 0;
                if (not (_reverse) and liquid.value0 > 0) {
                    conversionRate := (10 ** decimals) * liquid.value1 / liquid.value0;
                } else if (liquid.value1 > 0) {
                    conversionRate := (10 ** decimals) * liquid.value0 / liquid.value1;
                };
                if (conversionRate > 0) {
                    var req : RequestLog = {
                        request = { value = conversionRate; timestamp = _now() };
                        provider = provider;
                        time = _now();
                        signature = null;
                    };
                    ignore _setData(provider, _sid, req);
                };
            };
            case (_) {};
        };
    };
    private func _requestFromDex(_sid : SeriesId, _dexName : Text, _pair : Principal, _reverse : Bool) : async () {
        if (_dexName == "icswap") {
            await _requestFromICSwap(_sid, _pair, _reverse);
        };
    };
    private func _requestFromDexByTokens(_sid : SeriesId, _dexName : Text, _token0 : Principal, _token1 : Principal, _reverse : Bool) : async () {
        if (_dexName == "icswap") {
            let router : ICSRouter.Self = actor (icswapRouter);
            let temp = await router.route(_token0, _token1, ?_dexName);
            if (temp.size() > 0) {
                await _requestFromICSwap(_sid, temp[0].0, _reverse);
            };
        };
    };
    private func _requestIcpXdr() : async () {
        var sid : Nat = 1;
        let provider = Principal.fromActor(this);
        let minting : Minting.Self = actor ("rkp4c-7iaaa-aaaaa-aaaca-cai");
        let icpXdr = await minting.get_icp_xdr_conversion_rate();
        var req : RequestLog = {
            request = {
                value = Nat64.toNat(icpXdr.data.xdr_permyriad_per_icp);
                timestamp = Nat64.toNat(icpXdr.data.timestamp_seconds);
            };
            provider = provider;
            time = _now();
            signature = null;
        };
        ignore _setData(provider, sid, req);
        sid := 2;
        switch (_getDataItem(0, _now())) {
            case (?(xdrUsd)) {
                req := {
                    request = {
                        value = req.request.value * xdrUsd.1 / 10000;
                        timestamp = Nat64.toNat(icpXdr.data.timestamp_seconds);
                    };
                    provider = provider;
                    time = _now();
                    signature = null;
                };
                ignore _setData(provider, sid, req);
            };
            case (_) {};
        };
    };
    // https outcalls
    private func _textToNat(txt : Text) : Nat {
        assert (txt.size() > 0);
        let chars = txt.chars();
        var num : Nat = 0;
        for (v in chars) {
            if (Char.toNat32(v) == 10 or Char.toNat32(v) == 13 or Char.toNat32(v) == 32 or Char.toNat32(v) == 44 or Char.toNat32(v) == 95) {
                // \n \r (space) , _
                //skip
            } else {
                let charToNum = Nat32.toNat(Char.toNat32(v) - 48);
                assert (charToNum >= 0 and charToNum <= 9);
                num := num * 10 + charToNum;
            };
        };
        return num;
    };
    private func _textToFloat(txt : Text) : Float {
        //assert (txt.size() > 0);
        let chars = txt.chars();
        var num : Nat = 0;
        var res : Float = 0.0;
        var isDecimalPart : Bool = false;
        var decimalsCount : Nat = 0;
        for (v in chars) {
            if (Char.toNat32(v) == 10 or Char.toNat32(v) == 13 or Char.toNat32(v) == 32 or Char.toNat32(v) == 44 or Char.toNat32(v) == 95) {
                // \n \r (space) , _
                //skip
            } else if (Char.toNat32(v) == 46) {
                //.
                isDecimalPart := true;
                res := _natToFloat(num);
            } else if (Char.toNat32(v) >= 48 and Char.toNat32(v) <= 57) {
                let charToNum = Nat32.toNat(Char.toNat32(v) - 48);
                assert (charToNum >= 0 and charToNum <= 9);
                if (not (isDecimalPart)) {
                    num := num * 10 + charToNum;
                } else {
                    decimalsCount += 1;
                    res += _natToFloat(charToNum) / _natToFloat(10 ** decimalsCount);
                };
            };
        };
        if (not (isDecimalPart)) { res := _natToFloat(num) };
        return res;
    };
    private func _floatToNat(_data : Float, _decimals : Nat) : Nat {
        return Int.abs(Float.toInt(_data * _natToFloat(10 ** _decimals)));
    };

    public query func _call_transform(args : IC.TransformArgs) : async IC.CanisterHttpResponsePayload {
        let raw = args.response;
        let transformed : IC.CanisterHttpResponsePayload = {
            status = raw.status;
            body = raw.body;
            headers = [
                // {
                //     name = "Content-Security-Policy";
                //     value = "default-src 'self'";
                // },
                // { name = "Referrer-Policy"; value = "strict-origin" },
                // { name = "Permissions-Policy"; value = "geolocation=(self)" },
                // {
                //     name = "Strict-Transport-Security";
                //     value = "max-age=63072000";
                // },
                // { name = "X-Frame-Options"; value = "DENY" },
                // { name = "X-Content-Type-Options"; value = "nosniff" },
            ];
        };
        return transformed;
    };
    private func _decodeTS(_result : IC.CanisterHttpResponsePayload) : (Text, Nat) {
        var txt : Text = "";
        switch (Text.decodeUtf8(Blob.fromArray(_result.body))) {
            case null { assert (false); return ("", 0) };
            case (?decoded) {
                var i : Nat = 0;
                for (entry in Text.split(decoded, #text("\"timestamp\": "))) {
                    if (i == 1) {
                        var j : Nat = 0;
                        for (element1 in Text.split(entry, #text("\""))) {
                            if (j == 0) {
                                txt := element1;
                            };
                            j += 1;
                        };
                        if (j == 1) {
                            j := 0;
                            for (element1 in Text.split(entry, #text("}"))) {
                                if (j == 0) {
                                    txt := element1;
                                };
                                j += 1;
                            };
                        };
                    };
                    i += 1;
                };
                return (txt, _textToNat(txt));
            };
        };
    };
    private func _decodeFX(_result : IC.CanisterHttpResponsePayload, _curr : Text, _decimals : Nat) : (Text, Nat) {
        var txt : Text = "";
        switch (Text.decodeUtf8(Blob.fromArray(_result.body))) {
            case null { assert (false); return ("", 0) };
            case (?decoded) {
                var i : Nat = 0;
                for (entry in Text.split(decoded, #text("\"" # _curr # "\": "))) {
                    if (i == 1) {
                        var j : Nat = 0;
                        for (element1 in Text.split(entry, #text(","))) {
                            if (j == 0) {
                                txt := element1;
                            };
                            j += 1;
                        };
                        if (j == 1) {
                            j := 0;
                            for (element1 in Text.split(entry, #text(" }"))) {
                                if (j == 0) {
                                    txt := element1;
                                };
                                j += 1;
                            };
                        };
                    };
                    i += 1;
                };
                return (txt, _floatToNat(1 / _textToFloat(txt), _decimals));
            };
        };
    };
    private func _joinArgsFX() : Text {
        let trie = Trie.filter(
            seriesInfo,
            func(k : SeriesId, v : (SeriesInfo, Timestamp)) : Bool {
                _categoryCheck(#Currency, k) and v.0.sourceName == "apilayer";
            },
        );
        var args : Text = "";
        for ((sid, (info, ts)) in Trie.iter(trie)) {
            if (args.size() > 0) { args #= "," };
            args #= info.base;
        };
        return args;
    };
    private func _fetchFX() : async (Nat, Blob, Text, Nat) {
        // (Nat, Blob, Text,Nat)
        // var n1: Nat = 0;
        // var n2: Nat = 0;
        let host : Text = setting_apilayer.host;
        let request_headers = [
            // { name = "Host"; value = host # ":443" },
            // {
            //     name = "User-Agent";
            //     value = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36";
            // }, // Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36
            { name = "apikey"; value = setting_apilayer.key },
            { name = "User-Agent"; value = "ICOracle 0.0.1" },
        ];
        let request : IC.CanisterHttpRequestArgs = {
            // "https://api.apilayer.com/fixer/latest?base=USD&symbols=XDR,EUR,GBP,JPY,AUD,CHF,NZD,CAD,HKD,CNY,KRW"
            url = Text.replace(setting_apilayer.url, #text("{SYMBOLS}"), _joinArgsFX()); //"https://api.apilayer.com/exchangerates_data/latest?base=USD&symbols=XDR,EUR,GBP,JPY,AUD,CHF,NZD,CAD,HKD,SGD,CNY,KRW,TRY,INR,RUB,MXN,ZAR,SEK,DKK,THB,VND,MYR,TWD,BRL";
            max_response_bytes = ?Nat64.fromNat(MAX_RESPONSE_BYTES);
            headers = request_headers;
            body = null;
            method = #get;
            transform = ?{
                function = _call_transform;
                context = [];
            };
        };
        //try {
        Cycles.add(220_000_000_000);
        let ic : IC.Self = actor ("aaaaa-aa");
        let response = await ic.http_request(request);
        // n1 := response.body.size();
        // n2 := response.status;
        let provider = Principal.fromActor(this);
        let ts = _decodeTS(response);
        let timestamp = ts.1;
        for ((sid, (info, time)) in Trie.iter(seriesInfo)) {
            if (sid == 0 or (_categoryCheck(#Currency, sid) and info.sourceName == "apilayer")) {
                try {
                    let result = _decodeFX(response, info.base, info.decimals);
                    if (result.1 > 0) {
                        var req : RequestLog = {
                            request = {
                                value = result.1;
                                timestamp = timestamp;
                            };
                            provider = provider;
                            time = _now();
                            signature = null;
                        };
                        ignore _setData(provider, sid, req);
                    };
                    // return (response.status, Blob.fromArray(response.body), result.0, result.1);
                } catch (err) {};
            };
        };
        return (response.status, Blob.fromArray(response.body), request.url, ts.1);
        // } catch (err) {
        //     Debug.print(Error.message(err));
        //     return (0, Blob.fromArray([]), "Error", 0);
        // };
    };
    private func _decodeBA(_result : IC.CanisterHttpResponsePayload, _curr : Text, _decimals : Nat) : (Text, Nat) {
        var txt : Text = "";
        switch (Text.decodeUtf8(Blob.fromArray(_result.body))) {
            case null { assert (false); return ("", 0) };
            case (?decoded) {
                var i : Nat = 0;
                for (entry in Text.split(decoded, #text("\"" # _curr # "\",\"price\":\""))) {
                    if (i == 1) {
                        var j : Nat = 0;
                        for (element1 in Text.split(entry, #text("\"}"))) {
                            if (j == 0) {
                                txt := element1;
                            };
                            j += 1;
                        };
                    };
                    i += 1;
                };
                return (txt, _floatToNat(_textToFloat(txt), _decimals));
            };
        };
    };
    private func _joinArgsBA() : Text {
        let trie = Trie.filter(
            seriesInfo,
            func(k : SeriesId, v : (SeriesInfo, Timestamp)) : Bool {
                _categoryCheck(#Crypto, k) and v.0.sourceName == "binance";
            },
        );
        var args : Text = "";
        for ((sid, (info, ts)) in Trie.iter(trie)) {
            if (args.size() > 0) { args #= "," };
            args #= "%22" # info.base # info.quote # "%22";
        };
        return args;
    };
    private func _fetchBA() : async (Nat, Blob, Text, Nat) {
        // (Nat, Blob, Text,Nat)
        // var n1: Nat = 0;
        // var n2: Nat = 0;
        let host : Text = setting_binance.host;
        let request_headers = [
            { name = "Host"; value = host # ":443" },
            {
                name = "User-Agent";
                value = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36";
            }, // Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36
            //{ name = "apikey"; value = setting_binance.key },
            //{ name = "User-Agent"; value = "PostmanRuntime/7.29.2" }
        ];
        let request : IC.CanisterHttpRequestArgs = {
            // Text.replace(setting_binance.url, #text("{SYMBOLS}"), _joinArgsBA()); //
            url = Text.replace(setting_binance.url, #text("{SYMBOLS}"), _joinArgsBA()); // "https://api.binance.com/api/v3/ticker/price?symbols=[%22BTCUSDT%22,%22BNBUSDT%22]";
            max_response_bytes = ?Nat64.fromNat(MAX_RESPONSE_BYTES);
            headers = request_headers;
            body = null;
            method = #get;
            transform = ?{
                function = _call_transform;
                context = [];
            };
        };
        //for debug // return (0, Blob.fromArray([]), request.url, 0);
        //try {
        Cycles.add(220_000_000_000);
        let ic : IC.Self = actor ("aaaaa-aa");
        let response = await ic.http_request(request);
        // n1 := response.body.size();
        // n2 := response.status;
        let provider = Principal.fromActor(this);
        let timestamp = _now();
        for ((sid, (info, time)) in Trie.iter(seriesInfo)) {
            if (_categoryCheck(#Crypto, sid) and info.sourceName == "binance") {
                try {
                    let result = _decodeBA(response, info.base #info.quote, info.decimals);
                    if (result.1 > 0) {
                        var req : RequestLog = {
                            request = {
                                value = result.1;
                                timestamp = timestamp;
                            };
                            provider = provider;
                            time = _now();
                            signature = null;
                        };
                        ignore _setData(provider, sid, req);
                    };
                    // return (response.status, Blob.fromArray(response.body), result.0, result.1);
                } catch (err) {};
            };
        };
        return (response.status, Blob.fromArray(response.body), request.url, timestamp);
        // } catch (err) {
        //     Debug.print(Error.message(err));
        //     return (0, Blob.fromArray([]), "Error", 0);
        // };
    };
    private func _decodeCMC(_result : IC.CanisterHttpResponsePayload, _curr : Text, _decimals : Nat) : (Text, Nat) {
        var txt : Text = "";
        switch (Text.decodeUtf8(Blob.fromArray(_result.body))) {
            case null { assert (false); return ("", 0) };
            case (?decoded) {
                var i : Nat = 0;
                for (entry in Text.split(decoded, #text("\"" # _curr # "\""))) {
                    if (i == 1) {
                        var j : Nat = 0;
                        for (element1 in Text.split(entry, #text("\"price\":"))) {
                            if (j == 1) {
                                var k : Nat = 0;
                                for (element2 in Text.split(element1, #text(","))) {
                                    if (k == 0) {
                                        txt := element2;
                                    };
                                    k += 1;
                                };
                            };
                            j += 1;
                        };
                    };
                    i += 1;
                };
                return (txt, _floatToNat(_textToFloat(txt), _decimals));
            };
        };
    };
    public query func _cmc_transform(raw : IC.CanisterHttpResponsePayload) : async IC.CanisterHttpResponsePayload {
        var txt : Text = "";
        switch (Text.decodeUtf8(Blob.fromArray(raw.body))) {
            case null {};
            case (?decoded) {
                var i : Nat = 0;
                for (entry in Text.split(decoded, #text("\"data\":"))) {
                    if (i == 1) {
                        txt := entry;
                    };
                    i += 1;
                };
            };
        };
        let transformed : IC.CanisterHttpResponsePayload = {
            status = raw.status;
            body = Blob.toArray(Text.encodeUtf8(txt));
            headers = [
                {
                    name = "Content-Security-Policy";
                    value = "default-src 'self'";
                },
                { name = "Referrer-Policy"; value = "strict-origin" },
                { name = "Permissions-Policy"; value = "geolocation=(self)" },
                {
                    name = "Strict-Transport-Security";
                    value = "max-age=63072000";
                },
                { name = "X-Frame-Options"; value = "DENY" },
                { name = "X-Content-Type-Options"; value = "nosniff" },
            ];
        };
        return transformed;
    };
    private func _fetchCMC() : async (Nat, Blob, Text, Nat) {
        // (Nat, Blob, Text,Nat)
        // var n1: Nat = 0;
        // var n2: Nat = 0;
        let host : Text = setting_coinmarketcap.host;
        let request_headers = [
            { name = "Host"; value = host # ":443" },
            {
                name = "User-Agent";
                value = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36";
            }, // Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36
            { name = "CMC_PRO_API_KEY"; value = setting_coinmarketcap.key },
            //{ name = "User-Agent"; value = "PostmanRuntime/7.29.2" }
        ];
        let request : IC.CanisterHttpRequestArgs = {
            // Text.replace(setting_coinmarketcap.url, #text("{SYMBOLS}"), _joinArgsCMC()); //
            url = setting_coinmarketcap.url;
            max_response_bytes = ?Nat64.fromNat(MAX_RESPONSE_BYTES);
            headers = request_headers;
            body = null;
            method = #get;
            transform = ?{
                function = _call_transform;
                context = [];
            };
        };
        //for debug // return (0, Blob.fromArray([]), request.url, 0);
        //try {
        Cycles.add(220_000_000_000);
        let ic : IC.Self = actor ("aaaaa-aa");
        let response = await ic.http_request(request);
        // n1 := response.body.size();
        // n2 := response.status;
        let provider = Principal.fromActor(this);
        let timestamp = _now();
        for ((sid, (info, time)) in Trie.iter(seriesInfo)) {
            if (_categoryCheck(#Crypto, sid) and info.sourceName == "coinmarketcap") {
                try {
                    let result = _decodeCMC(response, info.base, info.decimals);
                    if (result.1 > 0) {
                        var req : RequestLog = {
                            request = {
                                value = result.1;
                                timestamp = timestamp;
                            };
                            provider = provider;
                            time = _now();
                            signature = null;
                        };
                        ignore _setData(provider, sid, req);
                    };
                    // return (response.status, Blob.fromArray(response.body), result.0, result.1);
                } catch (err) {};
            };
        };
        return (response.status, Blob.fromArray(response.body), request.url, timestamp);
        // } catch (err) {
        //     Debug.print(Error.message(err));
        //     return (0, Blob.fromArray([]), "Error", 0);
        // };
    };
    private func _decodeCB(_result : IC.CanisterHttpResponsePayload, _curr : Text, _decimals : Nat) : (Text, Nat) {
        var txt : Text = "";
        switch (Text.decodeUtf8(Blob.fromArray(_result.body))) {
            case null { assert (false); return ("", 0) };
            case (?decoded) {
                var i : Nat = 0;
                for (entry in Text.split(decoded, #text(","))) {
                    if (i == 4) {
                        txt := entry;
                    };
                    i += 1;
                };
                return (txt, _floatToNat(_textToFloat(txt), _decimals));
            };
        };
    };
    private func _fetchCB() : async (Nat, Blob, Text, Nat) {
        // (Nat, Blob, Text,Nat)
        // var n1: Nat = 0;
        // var n2: Nat = 0;
        let host : Text = setting_coinbase.host;
        let request_headers = [
            { name = "Host"; value = host # ":443" },
            {
                name = "User-Agent";
                value = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36";
            }, // Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36
            //{ name = ""; value = setting_coinbase.key },
            //{ name = "User-Agent"; value = "PostmanRuntime/7.29.2" }
        ];
        //try {
        // n1 := response.body.size();
        // n2 := response.status;
        let provider = Principal.fromActor(this);
        let timestamp = _now();
        var status : Nat = 200;
        var body : Blob = Blob.fromArray([]);
        for ((sid, (info, time)) in Trie.iter(seriesInfo)) {
            if (_categoryCheck(#Crypto, sid) and info.sourceName == "coinbase") {
                var url = Text.replace(setting_coinbase.url, #text("{SYMBOL_BASE}"), info.base);
                url := Text.replace(url, #text("{SYMBOL_QUOTE}"), info.quote);
                let end = _now();
                let start = Nat.sub(end, 180);
                url := Text.replace(url, #text("{START}"), Nat.toText(start));
                url := Text.replace(url, #text("{END}"), Nat.toText(end));
                let request : IC.CanisterHttpRequestArgs = {
                    //  //
                    url = url;
                    max_response_bytes = ?Nat64.fromNat(MAX_RESPONSE_BYTES);
                    headers = request_headers;
                    body = null;
                    method = #get;
                    transform = ?{
                        function = _call_transform;
                        context = [];
                    };
                };
                try {
                    Cycles.add(220_000_000_000);
                    let ic : IC.Self = actor ("aaaaa-aa");
                    let response = await ic.http_request(request);
                    let result = _decodeCB(response, info.base, info.decimals);
                    if (result.1 > 0) {
                        var req : RequestLog = {
                            request = {
                                value = result.1;
                                timestamp = timestamp;
                            };
                            provider = provider;
                            time = _now();
                            signature = null;
                        };
                        ignore _setData(provider, sid, req);
                    };
                    status := response.status;
                    body := Blob.fromArray(response.body);
                    // return (response.status, Blob.fromArray(response.body), result.0, result.1);
                } catch (err) {
                    status := 0;
                };
            };
        };
        return (status, body, setting_coinbase.url, timestamp);
        // } catch (err) {
        //     Debug.print(Error.message(err));
        //     return (0, Blob.fromArray([]), "Error", 0);
        // };
    };

    // public methods
    public query func getFee() : async Nat {
        return fee;
    };

    public query func getSeriesInfo(_sid : SeriesId) : async ?SeriesInfo {
        switch (Trie.get(seriesInfo, keyn(_sid), Nat.equal)) {
            case (?(item)) { return ?item.0 };
            case (_) { return null };
        };
    };
    // public query (msg) func anon_getSeries(_sid : SeriesId, _page : ?Nat) : async SeriesDataResponse {
    //     // assert(_onlyAnon(msg.caller));
    //     var info : SeriesInfo = _getSeriesInfo(_sid);
    //     if (info.heartbeat == 0) {
    //         return {
    //             name = info.name;
    //             sid = _sid;
    //             data = [];
    //             decimals = info.decimals;
    //         };
    //     };
    //     let page = Option.get(_page, 1);
    //     let periodSeconds = info.heartbeat * 500;
    //     return {
    //         name = info.name;
    //         sid = _sid;
    //         data = _getSeries(_sid, page, periodSeconds);
    //         decimals = info.decimals;
    //     };
    // };
    // public query (msg) func anon_get(_sid : SeriesId, _tsSeconds : ?Timestamp) : async ?DataResponse {
    //     // assert(_onlyAnon(msg.caller));
    //     var info : SeriesInfo = _getSeriesInfo(_sid);
    //     let ts = Option.get(_tsSeconds, _now());
    //     switch (_getDataItem(_sid, ts)) {
    //         case (?(res)) {
    //             return ?{
    //                 name = info.name;
    //                 sid = _sid;
    //                 data = res;
    //                 decimals = info.decimals;
    //             };
    //         };
    //         case (_) { return null };
    //     };
    // };
    // public query (msg) func anon_latest(_cat : T.Category) : async [DataResponse] {
    //     // assert(_onlyAnon(msg.caller));
    //     var res : [{
    //         name : Text;
    //         sid : SeriesId;
    //         decimals : Nat;
    //         data : (Timestamp, Nat);
    //     }] = [];
    //     for ((sid, info) in Trie.iter(seriesInfo)) {
    //         if (_categoryCheck(_cat, sid)) {
    //             switch (_getDataItem(sid, _now())) {
    //                 case (?(v)) {
    //                     res := Tools.arrayAppend(res, [{ name = info.0.name; sid = sid; decimals = info.0.decimals; data = v }]);
    //                 };
    //                 case (_) {};
    //             };
    //         };
    //     };
    //     return res;
    // };
    public query (msg) func getSeries(_sid : SeriesId, _page : ?Nat) : async SeriesDataResponse {
        var info : SeriesInfo = _getSeriesInfo(_sid);
        if (info.heartbeat == 0) {
            return {
                name = info.name;
                sid = _sid;
                data = [];
                decimals = info.decimals;
            };
        };
        // _chargeFee(msg.caller, 2);
        let page = Option.get(_page, 1);
        let periodSeconds = info.heartbeat * 500; // page size = 500
        return {
            name = info.name;
            sid = _sid;
            data = _getSeries(_sid, page, periodSeconds);
            decimals = info.decimals;
        };
    };
    public query (msg) func get(_sid : SeriesId, _tsSeconds : ?Timestamp) : async ?DataResponse {
        var info : SeriesInfo = _getSeriesInfo(_sid);
        let ts = Option.get(_tsSeconds, _now());
        switch (_getDataItem(_sid, ts)) {
            case (?(res)) {
                // _chargeFee(msg.caller, 1);
                return ?{
                    name = info.name;
                    sid = _sid;
                    data = res;
                    decimals = info.decimals;
                };
            };
            case (_) { return null };
        };
    };
    public query (msg) func latest(_cat : T.Category) : async [DataResponse] {
        var res : [{
            name : Text;
            sid : SeriesId;
            decimals : Nat;
            data : (Timestamp, Nat);
        }] = [];
        for ((sid, info) in Trie.iter(seriesInfo)) {
            if (_categoryCheck(_cat, sid)) {
                switch (_getDataItem(sid, _now())) {
                    case (?(v)) {
                        // _chargeFee(msg.caller, 2);
                        res := Tools.arrayAppend(res, [{ name = info.0.name; sid = sid; decimals = info.0.decimals; data = v }]);
                    };
                    case (_) {};
                };
            };
        };
        return res;
    };
    public query (msg) func volatility(_sid : SeriesId, _period : Nat) : async VolatilityResponse {
        var info : SeriesInfo = _getSeriesInfo(_sid);
        if (info.heartbeat == 0) {
            assert (false);
        };
        assert (_period <= info.heartbeat * 4320); // 1min*4320 = 3d   5min*4320 = 15d
        let s = _getSeries(_sid, 1, _period);
        var count : Nat = 0;
        var sum : Nat = 0;
        var open : Nat = 0;
        var high : Nat = 0;
        var low : Nat = 0;
        var close : Nat = 0;
        var avg : Nat = 0;
        for ((ts, v) in s.vals()) {
            count += 1;
            sum += v;
            if (count == 1) { open := v };
            if (v > high) { high := v };
            if (v < low or low == 0) { low := v };
            close := v;
        };
        var res : Float = 0;
        if (count > 0 and sum > 0) {
            avg := sum / count;
            res := _natToFloat(high - low) / _natToFloat(avg);
            // _chargeFee(msg.caller, 3);
        };
        return {
            open = open;
            high = high;
            low = low;
            close = close;
            average = avg;
            percent = res;
            decimals = info.decimals;
        };
    };
    public query func getLog(_sid : SeriesId, _tsSeconds : ?Timestamp) : async ?Log {
        let ts = Option.get(_tsSeconds, _now());
        var info : SeriesInfo = _getSeriesInfo(_sid);
        if (info.heartbeat == 0) {
            assert (false);
        };
        let pid = ts / info.heartbeat;
        return _getLog(_sid, pid);
    };
    // request '(0, record{value=12751; timestamp=1665583587;}, null)'
    public shared (msg) func request(_sid : SeriesId, _data : DataItem, signature : ?Blob) : async (confirmed : Bool) {
        assert (_onlyProvider(msg.caller, _sid));
        let provider = _getProvider(msg.caller);
        let req : RequestLog = {
            request = _data;
            provider = provider;
            time = _now();
            signature = signature;
        };
        return _setData(provider, _sid, req);
    };
    public query func getWorkload(_account : Provider) : async ?(score : Nat, invalid : Nat) {
        return Trie.get(workloads, keyp(_account), Principal.equal);
    };

    // Debug
    public shared (msg) func debug_fetchFX() : async (Nat, Blob, Text, Nat) {
        // (Nat, Blob, Text, Nat)
        assert (_onlyOwner(msg.caller));
        return await _fetchFX();
    };
    public shared (msg) func debug_fetchBA() : async (Nat, Blob, Text, Nat) {
        // (Nat, Blob, Text, Nat)
        assert (_onlyOwner(msg.caller));
        return await _fetchBA();
    };
    public shared (msg) func debug_fetchCB() : async (Nat, Blob, Text, Nat) {
        // (Nat, Blob, Text, Nat)
        assert (_onlyOwner(msg.caller));
        return await _fetchCB();
    };
    public shared (msg) func debug_fetchCMC() : async (Nat, Blob, Text, Nat) {
        // (Nat, Blob, Text, Nat)
        assert (_onlyOwner(msg.caller));
        return await _fetchCMC();
    };
    public shared (msg) func debug_requestIcpXdr() : async () {
        assert (_onlyOwner(msg.caller));
        await _requestIcpXdr();
    };

    // Governance

    // Manage
    public shared (msg) func setFee(_fee : Nat) : async () {
        assert (_onlyOwner(msg.caller));
        fee := _fee;
    };
    // setApi '("apilayer", record{name="apilayer"; host="api.apilayer.com"; url="https://api.apilayer.com/exchangerates_data/latest?base=USD&symbols={SYMBOLS}"; key="......"})'        // {SYMBOLS} = XDR,EUR,GBP,JPY
    // setApi '("binance", record{name="binance"; host="api.binance.com"; url="https://api.binance.com/api/v3/ticker/price?symbols=[{SYMBOLS}]"; key=""})'        // {SYMBOLS} = %22BTCUSDT%22,%22BNBUSDT%22
    // setApi '("coinmarketcap", record{name="coinmarketcap"; host="pro.coinmarketcap.com"; url="https://pro-api.coinmarketcap.com/v1/cryptocurrency/listings/latest?start=1&limit=50&convert=USD"; key="......"})'
    // setApi '("coinbase", record{name="coinbase"; host="api.pro.coinbase.com"; url="https://api.pro.coinbase.com/products/{SYMBOL_BASE}-{SYMBOL_QUOTE}/candles?start={START}&end={END}&granularity=60"; key=""})'
    // // setApi '("coinbase", record{name="coinbase"; host="api.exchange.coinbase.com"; url="https://api.exchange.coinbase.com/products/{SYMBOL_BASE}-{SYMBOL_QUOTE}/ticker"; key=""})'
    public shared (msg) func setApi(_type : Text, _value : T.OutCallAPI) : async Bool {
        assert (_onlyOwner(msg.caller));
        if (_type == "apilayer") {
            setting_apilayer := _value;
            return true;
        } else if (_type == "binance") {
            setting_binance := _value;
            return true;
        } else if (_type == "coinbase") {
            setting_coinbase := _value;
            return true;
        } else if (_type == "coinmarketcap") {
            setting_coinmarketcap := _value;
            return true;
        };
        return false;
    };
    public shared (msg) func setProvider(_account : Provider, _sids : [SeriesId], _agents : [Principal]) : async () {
        assert (_onlyOwner(msg.caller));
        providers := List.push((_account, _sids, _agents), providers);
    };
    public shared (msg) func addProviderSid(_account : Provider, _sid : SeriesId) : async () {
        assert (_onlyOwner(msg.caller));
        switch (List.find(providers, func(t : (Provider, [SeriesId], [Principal])) : Bool { _account == t.0 })) {
            case (?(provider)) {
                providers := List.filter(providers, func(t : (Provider, [SeriesId], [Principal])) : Bool { t.0 != _account });
                providers := List.push((provider.0, Tools.arrayAppend(provider.1, [_sid]), provider.2), providers);
            };
            case (_) { assert (false) };
        };
    };
    public shared (msg) func delProviderSid(_account : Provider, _sid : SeriesId) : async () {
        assert (_onlyOwner(msg.caller));
        switch (List.find(providers, func(t : (Provider, [SeriesId], [Principal])) : Bool { _account == t.0 })) {
            case (?(provider)) {
                providers := List.filter(providers, func(t : (Provider, [SeriesId], [Principal])) : Bool { t.0 != _account });
                providers := List.push((provider.0, Array.filter(provider.1, func(t : SeriesId) : Bool { t != _sid }), provider.2), providers);
            };
            case (_) { assert (false) };
        };
    };
    public shared (msg) func addProviderAgent(_account : Provider, _agent : Principal) : async () {
        assert (_onlyOwner(msg.caller));
        switch (List.find(providers, func(t : (Provider, [SeriesId], [Principal])) : Bool { _account == t.0 })) {
            case (?(provider)) {
                providers := List.filter(providers, func(t : (Provider, [SeriesId], [Principal])) : Bool { t.0 != _account });
                providers := List.push((provider.0, provider.1, Tools.arrayAppend(provider.2, [_agent])), providers);
            };
            case (_) { assert (false) };
        };
    };
    public shared (msg) func delProviderAgent(_account : Provider, _agent : Principal) : async () {
        assert (_onlyOwner(msg.caller));
        switch (List.find(providers, func(t : (Provider, [SeriesId], [Principal])) : Bool { _account == t.0 })) {
            case (?(provider)) {
                providers := List.filter(providers, func(t : (Provider, [SeriesId], [Principal])) : Bool { t.0 != _account });
                providers := List.push((provider.0, provider.1, Array.filter(provider.2, func(t : Principal) : Bool { t != _agent })), providers);
            };
            case (_) { assert (false) };
        };
    };
    public shared (msg) func removeProvider(_account : Provider) : async () {
        assert (_onlyOwner(msg.caller));
        providers := List.filter(providers, func(t : (Provider, [SeriesId], [Principal])) : Bool { t.0 != _account });
    };
    public shared (msg) func setDexSupport(_dex : Text, _router : Principal) : async () {
        assert (_onlyOwner(msg.caller));
        dexs := Trie.put(dexs, keyt(_dex), Text.equal, _router).0;
    };
    public shared (msg) func newSeriesInfo(_sid : SeriesId, _info : SeriesInfo) : async Bool {
        assert (_onlyOwner(msg.caller));
        assert (Option.isNull(Trie.get(seriesInfo, keyn(_sid), Nat.equal)));
        seriesInfo := Trie.put(seriesInfo, keyn(_sid), Nat.equal, (_info, _now())).0;
        if (_sid > index) { index := _sid };
        return true;
    };
    public shared (msg) func updateSeriesInfo(_sid : SeriesId, _info : SeriesInfo) : async Bool {
        assert (_onlyOwner(msg.caller));
        assert (Option.isSome(Trie.get(seriesInfo, keyn(_sid), Nat.equal)));
        seriesInfo := Trie.put(seriesInfo, keyn(_sid), Nat.equal, (_info, _getSeriesCreationTime(_sid))).0;
        //if (_sid > index) { index := _sid };
        return true;
    };
    public shared (msg) func delSeriesData(_sid : SeriesId) : async Bool {
        assert (_onlyOwner(msg.caller));
        assert (Option.isSome(Trie.get(seriesInfo, keyn(_sid), Nat.equal)));
        seriesInfo := Trie.remove(seriesInfo, keyn(_sid), Nat.equal).0;
        seriesData := Trie.remove(seriesData, keyn(_sid), Nat.equal).0;
        return true;
    };

    // DRC207 ICMonitor
    /// DRC207 support
    public func drc207() : async DRC207.DRC207Support {
        return {
            monitorable_by_self = true;
            monitorable_by_blackhole = {
                allowed = false;
                canister_id = ?Principal.fromText("7hdtw-jqaaa-aaaak-aaccq-cai");
            };
            cycles_receivable = true;
            timer = { enable = false; interval_seconds = null };
        };
    };
    /// canister_status
    public func canister_status() : async DRC207.canister_status {
        let ic : DRC207.IC = actor ("aaaaa-aa");
        await ic.canister_status({ canister_id = Principal.fromActor(this) });
    };

    //return cycles balance
    public query func wallet_balance() : async Nat {
        return Cycles.balance();
    };

    /// receive cycles
    public func wallet_receive() : async () {
        let amout = Cycles.available();
        let accepted = Cycles.accept(amout);
    };
    /// timer tick
    // public func timer_tick(): async (){
    //     let f = _requestIcpXdr();
    // };

    // http request
    public query func http_request(req : ICHTTP.HttpRequest) : async ICHTTP.HttpResponse {
        switch (req.method, not Option.isNull(Array.find(req.headers, ICHTTP.isGzip)), req.url) {
            case ("GET", _, path) {
                var i : Nat = 0;
                var baseToken : Text = "";
                var quoteToken : Text = "";
                for (entry in Text.split(path, #text("/"))) {
                    if (entry.size() > 0) {
                        if (i == 0) {
                            baseToken := entry;
                        };
                        if (i == 1) {
                            quoteToken := entry;
                        };
                        i += 1;
                    };
                };
                let ts = _now();
                var response : Text = "";
                var sids : [Nat] = [];
                var error : Bool = false;
                if (baseToken.size() > 0 and quoteToken.size() > 0) {
                    let s = Trie.filter(
                        seriesInfo,
                        func(k : Nat, v : (SeriesInfo, Timestamp)) : Bool {
                            v.0.base == baseToken and v.0.quote == quoteToken;
                        },
                    );
                    if (Trie.size(s) == 0) {
                        error := true;
                        response := "{\"error\": {\"code\": 400, \"message\": \"Unavailable data\"}}";
                    } else {
                        for ((k, v) in Trie.iter(s)) {
                            sids := Tools.arrayAppend(sids, [k]);
                        };
                    };
                } else {
                    try {
                        sids := Tools.arrayAppend(sids, [_textToNat(Text.replace(path, #text("/"), ""))]);
                    } catch (e) {
                        error := true;
                        response := "{\"error\": {\"code\": 400, \"message\": \"Unavailable data\"}}";
                    };
                };
                var status : Nat16 = 200;
                if (not (error)) {
                    var resData : Text = "";
                    for (sid in sids.vals()) {
                        try {
                            var info : SeriesInfo = _getSeriesInfo(sid);
                            switch (_getDataItem(sid, ts)) {
                                case (?(timestamp, value)) {
                                    if (resData.size() > 0) { resData #= ", " };
                                    resData #= "{\"name\": \"" # info.name # "\", \"sid\": \"" # Nat.toText(sid) # "\", \"base\": \"" # info.base # "\", \"quote\": \"" # info.quote # "\", \"rate\": " # Float.toText(_natToFloat(value) / _natToFloat(10 ** info.decimals)) # ", \"timestamp\": " # Nat.toText(timestamp) # " }";
                                };
                                case (_) {};
                            };
                        } catch (e) {};
                    };
                    if (resData.size() > 0) {
                        response := "{\"success\": [" # resData # "]}";
                    } else {
                        status := 400;
                        response := "{\"error\": {\"code\": 400, \"message\": \"Unavailable data\"}}";
                    };
                } else {
                    status := 400;
                    response := "{\"error\": {\"code\": 400, \"message\": \"Unavailable data\"}}";
                };
                return {
                    status_code = status;
                    headers = [("content-type", "text/plain")];
                    body = Text.encodeUtf8(response);
                    streaming_strategy = null;
                    upgrade = null;
                };
            };
            case ("POST", _, _) {
                {
                    status_code = 204;
                    headers = [];
                    body = "";
                    streaming_strategy = null;
                    upgrade = ?true;
                };
            };
            case _ {
                {
                    status_code = 400;
                    headers = [];
                    body = "Invalid request";
                    streaming_strategy = null;
                    upgrade = null;
                };
            };
        };
    };

    // heartbeat
    private stable var LastUpdated_IcpXdr : Nat = 0;
    private func _heartbeat_fetchIcpXdr() : async () {
        let hbid = Int.abs(Time.now()) / 600000000000; // 600s
        if (hbid > LastUpdated_IcpXdr and Int.abs(Time.now()) >= hbid * 600000000000 + 60000000000) {
            // 60s
            LastUpdated_IcpXdr := hbid;
            await _requestIcpXdr();
        };
    };
    public shared (msg) func test_heartbeat_fetchIcpXdr() : async (Nat) {
        assert (_onlyOwner(msg.caller));
        await _heartbeat_fetchIcpXdr();
        return LastUpdated_IcpXdr;
    };
    private stable var LastUpdated_FX : Nat = 0;
    private stable var Retry_FX : Time.Time = 0;
    private func _heartbeat_fetchFX() : async () {
        let update_time = 3600000000000 * 6; //6h
        let hbid = Int.abs(Time.now()) / update_time;
        if (hbid > LastUpdated_FX and Int.abs(Time.now()) >= hbid * update_time + 60000000000) {
            // 60s
            LastUpdated_FX := hbid;
            if ((await _fetchFX()).0 == 0) {
                Retry_FX := Time.now();
            };
        };
        if (Retry_FX > 0 and Time.now() > Retry_FX + 10000000000) {
            // 10s
            Retry_FX := 0;
            ignore await _fetchFX();
        };
    };
    public shared (msg) func test_heartbeat_fetchFX() : async (Nat) {
        assert (_onlyOwner(msg.caller));
        await _heartbeat_fetchFX();
        return LastUpdated_FX;
    };
    private stable var LastUpdated_BA : Nat = 0;
    private stable var Retry_BA : Time.Time = 0;
    private func _heartbeat_fetchBA() : async () {
        let hbid = Int.abs(Time.now()) / 600000000000; // 10min
        if (hbid > LastUpdated_BA) {
            //
            LastUpdated_BA := hbid;
            if ((await _fetchBA()).0 == 0) {
                Retry_BA := Time.now();
            };
        };
        if (Retry_BA > 0 and Time.now() > Retry_BA + 2000000000) {
            // 2s
            Retry_BA := 0;
            ignore await _fetchBA();
        };
    };
    public shared (msg) func test_heartbeat_fetchBA() : async (Nat) {
        assert (_onlyOwner(msg.caller));
        await _heartbeat_fetchBA();
        return LastUpdated_BA;
    };
    private stable var LastUpdated_CMC : Nat = 0;
    private stable var Retry_CMC : Time.Time = 0;
    private func _heartbeat_fetchCMC() : async () {
        let hbid = Int.abs(Time.now()) / 3600000000000; // 1h
        if (hbid > LastUpdated_CMC) {
            //
            LastUpdated_CMC := hbid;
            if ((await _fetchCMC()).0 == 0) {
                Retry_CMC := Time.now();
            };
        };
        if (Retry_CMC > 0 and Time.now() > Retry_CMC + 5000000000) {
            // 5s
            Retry_CMC := 0;
            ignore await _fetchCMC();
        };
    };
    public shared (msg) func test_heartbeat_fetchCMC() : async (Nat) {
        assert (_onlyOwner(msg.caller));
        await _heartbeat_fetchCMC();
        return LastUpdated_CMC;
    };
    private stable var LastUpdated_CB : Nat = 0;
    private stable var Retry_CB : Time.Time = 0;
    private func _heartbeat_fetchCB() : async () {
        let hbid = Int.abs(Time.now()) / 3600000000000; // 1h
        if (hbid > LastUpdated_CB) {
            //
            LastUpdated_CB := hbid;
            if ((await _fetchCB()).0 == 0) {
                Retry_CB := Time.now();
            };
        };
        if (Retry_CB > 0 and Time.now() > Retry_CB + 5000000000) {
            // 5s
            Retry_CB := 0;
            ignore await _fetchCB();
        };
    };
    public shared (msg) func test_heartbeat_fetchCB() : async (Nat) {
        assert (_onlyOwner(msg.caller));
        await _heartbeat_fetchCB();
        return LastUpdated_CB;
    };
    system func heartbeat() : async () {
        await _heartbeat_fetchFX();
        //await _heartbeat_fetchBA();
        //await _heartbeat_fetchCMC();
        // await _heartbeat_fetchCB();
        await _heartbeat_fetchIcpXdr();
    };

};

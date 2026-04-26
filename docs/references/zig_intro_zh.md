https://www.youtube.com/watch?v=Gv2I7qTux7g

這支「The Road to Zig 1.0」主要在說明：為什麼需要 Zig，以及 Zig 如何在「像 C 一樣低階但更安全、可重用」的前提下設計語言與工具鏈。

為什麼需要新語言 Zig

Andrew 一開始對比了飛機、電梯和軟體工程師：前兩者會說「很安全、有多重保護機制」，軟體工程師對「電腦化投票」卻會說「超可怕，我們一做錯大家都會死」。他的核心問題是：要怎樣寫出真正高可靠、可重用的系統軟體。

他提出一個「避免程式碼被廣泛重用」的反面清單：
垃圾回收造成不可預期的停頓（不適合即時系統）、自動 heap 配置導致 OOM 當機或卡死、效能比 C 慢會被重寫、沒有 C ABI 就很難被其他語言呼叫，還有難以從原始碼建置（像 TensorFlow）。如果你踩到這些，就很難讓軟體在關鍵系統或多語言環境被廣泛使用。

沿著這個標準，他把主流語言幾乎全部劃掉，只剩下 C / C++ / 組合語言。組合太不實際、C++ 過於複雜且容易誤用，最後只剩 C；但 C 本身又有 include 機制、前處理器、到處是 undefined behavior 等問題，使高品質軟體很難寫對。

所以他的結論是：從 C 出發，把壞掉的地方修掉，就變成 Zig。

Zig 如何「修補 C」：compile-time 與沒有 preprocessor

他先示範 C 中一個看似合理卻行不通的範例：想宣告一個 global const 為字串長度，用它當陣列大小，卻因為「initializer 不是 compile-time constant」而編譯失敗，逼你手動寫魔法數字，還可能造成 buffer overflow。另一個例子是，在函式內使用看似是常數的值，其實被當成 variable-length array，導致潛在 stack overflow。

這些實務上的坑，常常只能用 preprocessor macro 來繞過，結果又帶來新的問題：
你看一段 C 程式碼，表面邏輯很直觀，但其實上面有個 ⁠#define⁠ 把 ⁠if (x)⁠ 改成完全不一樣的語意，讓你完全無法只靠「局部上下文」理解程式。前處理器是另一個語言，跟 C 不互相了解，也破壞 IDE 與 API 綁定。

Zig 的做法是：直接刪掉 ⁠#include⁠ / ⁠#define⁠，把 preprocessor 整個移除。然後，讓「一切都是 expression」，而且 expression 可以在 compile-time 被求值。

他示範了同樣的程式在 Zig 裡：

- 型別也是 expression（例如 ⁠u8⁠）；

- 字串 /函式呼叫也是 expression；

- 只要能在編譯期計算出來，就可以當成常數使用。

若你想強迫某段程式一定在編譯期求值，就加上 ⁠comptime⁠ 關鍵字。如果 Zig 發現無法在編譯期執行（例如呼叫外部函式、inline assembly、亂 deref 指標），就給你 compile error，而不是讓行為未定義。

這個設計自然而然帶出幾個能力：

- 條件編譯不再用 preprocessor，而是普通 ⁠if⁠：
如果條件值在編譯期已知，死分支會被靜態消掉，錯誤訊息也不會出現，整個語言只剩一套語意。

- ⁠comptime⁠ +「型別也是值」的組合，自然產生了泛型（generics）：函式可以把一個型別當參數，回傳新的型別，不需要額外的語法魔法或編譯器內建。

他特別強調：自己不是戴著「語言理論帽」設計一大堆高深抽象，而是「看到 C 壞掉的地方就修掉」，結果像 ⁠comptime⁠、泛型這種功能是「自然掉出來的副產品」。

把錯誤處理變成「最懶的那條正確路」

Zig 把「錯誤處理」當成語言中心主題之一。Andrew 的哲學是：人一定會偷懶，所以要讓「最懶的方法」同時也是「正確處理錯誤的方法」，才有機會讓整體軟體品質提升。

他先展示一個 C 範例：⁠open⁠ 一個不存在的檔案，完全不檢查回傳值，直接 ⁠write⁠、⁠close⁠，最後 exit code 還是 0。用 ⁠strace⁠ 看才會發現整個流程一直在錯誤中繼續執行，卻沒有被程式表達出來。

在 Zig 版本裡，若你照樣「不處理錯誤」，程式根本不會編譯。因為：

- 會回傳錯誤的函式，回傳型別會註記為「可能錯誤」；

- 你必須用 ⁠try⁠ 或 ⁠catch⁠ 之類的語法顯式處理，否則 compile error。

⁠try⁠ 的語意類似 Rust 的 ⁠?⁠：如果結果是錯誤，就把錯誤泡泡往上回傳；若成功，就給你值。差別在於 Zig 把「錯誤集（error sets）」做成型別系統的一部分：

- 你可以 ⁠switch⁠ 在錯誤上，編譯器會列出「所有可能的錯誤值」；

- 如果你漏掉某個錯誤 case，或寫了不可能發生的錯誤，編譯器會提醒你，確保錯誤處理是完整且與 API 同步演進；

- 新增一個錯誤值，本身就被視為「破壞性 API 變更」，因為下游呼叫端必須更新處理邏輯。

此外，Zig 在錯誤回傳上還有「error return trace」的概念：它記錄錯誤最初發生的位置以及沿途 propagate 的路徑，和一般 runtime stack trace 無縫銜接在一起。當你用一種不安全的方式「解開錯誤」（例如 ⁠catch unreachable⁠，宣稱某錯誤絕不可能發生，結果真的發生了），Zig 在 debug 模式中會給出錯誤名稱、錯誤回傳路徑和實際 stack trace，幫你快速定位問題。

清理資源：⁠defer⁠ / ⁠errdefer⁠ 解決 C 的「錯誤清理地獄」

他拿一段用 C 寫的、使用 LibSoundIO 產生正弦波的程式作例子：為了正確釋放每一個成功配置的資源，各種 ⁠if (error) { free earlier stuff; return; }⁠ 疊成深深的縮排，「腦中需要畫很多箭頭」才能確保沒漏掉任何清理，也就是典型的「錯誤清理地獄」。

接著他展示 C 常用的 ⁠goto cleanup⁠ 模式：雖然將清理集中在尾端比較整齊，但會帶來變數必須提早宣告、引入暫時為 ⁠null⁠ 的狀態等副作用，依然容易出錯。

Zig 則有兩個關鍵語法：

- ⁠defer⁠：無論是正常離開還是錯誤返回，只要離開 scope，就會照宣告順序反向執行 ⁠defer⁠ 區塊，類似 Go 的 ⁠defer⁠。

- ⁠errdefer⁠：只在「因為錯誤而離開函式」時才執行，用於「成功時要保留資源，但失敗時要釋放」的情境。

於是，真正的 Zig 程式碼可以長得短小、線性：每個資源在配置後緊跟著對應的 ⁠defer⁠ 或 ⁠errdefer⁠，不再需要巢狀的錯誤路徑與 ⁠goto⁠，而且這段示例程式仍然是在叫 C 函式庫。Andrew 強調：「Zig 在使用 C library 這件事上，比 C 自己還強。」

Build system 與「Zig 當 C 編譯器與跨平台工具鏈」

後半段他換一個痛點：建置系統（build system）和依賴地獄。以 libpng 為例，他打開壓縮檔看到：

- 需要 C 編譯器；

- 有 autotools 產生的檔案、需要 POSIX shell；

- 為了 Windows 又加入 CMake；

- 還有外部依賴 zlib。

這些東西混在一起導致「要建這套庫，你的環境必須裝一堆彼此不同、還得相依的平台工具」。

他想像如果 libpng 是用 Zig 寫的，只需要：

- ⁠src.zig⁠（實作）

- ⁠build.zig⁠（建置腳本）

所有平台共用同一套 Zig build system，不需要混雜 autotools / CMake / shell script。

接著他再往前一步：即使你不想用 Zig 寫 libpng 本體，也可以只用 Zig 的 build system 來幫你編 C。因為：

- Zig 本來就要能解析 C header 與呼叫 C 函式，所以已經依賴 libclang；

- 直接讓 ⁠zig cc⁠ 當作 C 編譯器入口：傳給它的參數會轉給 clang，並加上一些 Zig 負責的旗標。

這樣 Zig 實際上成了一個「包著 clang 的 C 編譯器前端」，並且：

- 自動開啟 make-style 依賴檔案生成；

- 用內建的 cache 系統重用 C 編譯結果，不再需要 ⁠make⁠；

- 對 native target 預設開啟像 ⁠-march=native⁠ 這種較進取的最佳化（而仍可以 cross-compile 到其他平台）。

更大的一步是：Zig 隨附了多種 libc（例如 musl、glibc start files）的 header 與 source，並能在需要時為目標平台「懶生成」對應的 libc，然後快取起來。結果就是：

- 你可以用 Zig 輕鬆 cross-compile Zig 程式到 arm64 等架構；

- 也可以用 Zig cross-compile C 程式，選擇要連結哪一種 libc、是否要靜態連結。

在這樣的設計下，Zig 不只是語言，而是一個跨平台的完整工具鏈。

Zig 與 Rust 的關係與安全哲學

在 Q&A 中，難免被問到「為什麼是 Zig 而不是 Rust」。Andrew 的看法大致是：

- 他非常肯定 Rust 語言本身的設計，兩者目標都指向高可靠系統程式。

- 就他列出的幾個條件來看（沒有 GC 停頓、能用 C ABI、適合內核/嵌入…），Rust 語言都符合；比較有爭議的是 Rust 標準庫，在一些預設 allocator、環境假設上，可能讓某些場景較難使用。

- Zig 在設計上更強調「簡單」與「最小化」，願意接受比 Rust 更大的危險區（沒有 borrow checker），換取語言本體與工具的直覺與可控。

安全性方面，他說得很誠實：Zig 現況不是「安全語言」，很多 bug 在 release-fast 之類模式下仍會變成 undefined behavior。但：

- 在 debug / release-safe 模式下，Zig 會盡可能把 undefined behavior 變成「立即崩潰 + 有用訊息」，例如越界、用完釋放記憶體後再使用等；

- 他正在推進提案，希望未來在這兩種模式下，能「幾乎完全安全」，把剩下的未定義行為也儘量改成有檢查的錯誤。

總結：Zig 的幾個關鍵特色

綜合整支影片，Zig 想做的事可以簡單整理成幾點：

- 在 C 的效能與控制力之上，移除 preprocessor 與大量 undefined behavior，讓語言本體更可預測、可分析。

- 用 ⁠comptime⁠ 把「編譯期執行程式」變成一等公民，順帶獲得更強的常數運算、條件編譯與泛型能力。

- 讓錯誤處理成為語言級型別系統的一部分，搭配 error trace / stack trace / ⁠try⁠ / ⁠catch⁠ / ⁠errdefer⁠，讓「正確處理錯誤」變成最自然、最省力的寫法。

- 內建跨平台 build system 和 C 編譯能力，藉由捆綁 libc 與 libclang，提供一套「到處都一樣」的工具鏈，既能用 Zig，也能幫你編譯 C 與 cross-compile。

最後他強調，這些都不是概念影片，而是當時就已經在實作中的功能，可以下載 Zig 直接使用。


https://www.youtube.com/watch?v=YXrb-DqsBNU

這支影片主要介紹 Zig 語言本身，以及它背後的專案與基金會定位，重點可以分成幾個部分來看。

1. 從「找 bug」開始：語言設計理念

一開始 Andrew 用一段 Zig 反射／巨集程式碼請大家「找 bug」。多數人第一次看到 Zig 也能在短時間內找出問題（少處理了一種整數型別，導致 switch 不完整）。他藉這個例子強調：

- Zig 的語法與抽象刻意保持簡單、直覺，讓你花更多時間在理解程式邏輯，而不是跟語言細節打架。

- 像反射、泛型這種通常很難讀的部分，在 Zig 裡也力求簡潔、可預測（例如 inline for、comptime 型別反射）。

2. Zig 專案是什麼？目標與價值觀

他把 Zig 描述為「通用程式語言 + 工具鏈」，核心目標是協助維護強健、效能佳且可重用的軟體，並「把軟體這門工藝的水準往上拉」。

重點價值觀包括：

- 重新檢視底層假設：

 ▫ 不預設有全域 allocator，而是顯式傳遞 allocator。

 ▫ 不強迫依賴 libc，方便做真正靜態連結、跨平台、遊戲／嵌入式等場景。

- 著重工具鏈與基礎建設：

 ▫ 提供 Zig CC、建構系統、未來的高品質 C ABI 函式庫，讓所有語言都能受益。

- 關注學生與教育，希望培養具職業道德、重視品質的新一代工程師。

3. 「Maintain it with Zig」三層使用方式

他提出一個「分三層」的 adoption 路徑，強調你不一定要改寫成 Zig 才能受益。

Level 1：只把 Zig 當 C/C++ 編譯器（zig cc）

- Uber 等公司用 zig cc 來做到「hermetic builds」：編譯不依賴系統已安裝什麼，任何開發者在任何 OS 都能產出一致的 build。

- zig cc 預設開啟更積極的安全檢查，例如 Undefined Behavior Sanitizer，實際在 SDL 這種成熟專案裡都能找到 bug。

- 內建強大的跨編譯能力：

 ▫ 一個 flag 指定目標平台（例如 x86_64-windows 或 arm64-macos），就能從任意 host cross compile。

 ▫ 可以鎖定特定 glibc 版本、用 musl 做真正 distro‑independent 靜態 binary。

- 內建快取：Zig 本來就需要快取 libc / compiler-rt 等，順便也把 C/C++ 物件一併快取，改一個檔再編譯速度非常快。

- 安裝超輕量：下載 60MB 壓縮檔解壓即用，對比 Visual Studio 動輒數小時、重開機的安裝體驗。

Level 2：使用 Zig build 系統

- 用 ⁠build.zig⁠ 取代複雜的 Makefile / CMake，把「要編哪些 C 檔、如何組合」寫成型別安全、可抽象的 Zig 程式。

- build 指令會自動產生 help，內含你自己定義的 build step 與選項（例如 ⁠zig build play⁠）。

- 日後會進一步支援 C/C++ 相依套件的解決與下載，使跨平台協作更穩定、不依賴各自系統環境。

Level 3：在現有專案中加入一些 Zig code

- 既然 build 系統已經依賴 Zig，就可以開始把某些元件用 Zig 寫。

- C 與 Zig 互調非常順：

 ▫ 在 Zig 中 ⁠export⁠ 函式供 C 呼叫，或宣告 ⁠extern⁠ C 函式供 Zig 呼叫。

 ▫ Stack trace 可以同時顯示 C 與 Zig 呼叫鏈。

- 利用 Link-Time Optimization，Zig 函式與 C 函式之間可做整體最佳化，有些計算甚至會被「直接折疊成常數」。

4. 非營利 vs VC：Zig Software Foundation 的定位

中段他講了一大塊「怎麼預測未來」，其實是在說組織型態會決定專案長期會變成什麼樣子：

- VC 支持的新創常見路線：

 ▫ 初期用燒錢堆出「誘人但不可持續」的產品；

 ▫ 幾年後資本壓力加大，開始向員工與使用者「榨取價值」；

 ▫ 接著不是被大公司買走、產品壽命結束，就是自己長成另一家大公司，價值觀轉變。

- 相比之下，非營利組織需將盈餘再投入使命本身，成功的衡量是「是否實現使命」，而不是股東獲利。

- 他用 Wikipedia（非營利）與 Google（商業公司）並列，說明 20 多年下來兩者口碑與行為的巨大差異。

- Zig Software Foundation 本身是 501(c)(3) 非營利：

 ▫ 已達到財務穩定，收入大於開銷，多的錢拿來支付貢獻者。

 ▫ 沒有 VC、沒有「Runway 用完就得 pivot／關門」的壓力。

 ▫ 由董事會治理，不是他個人說了算，所以就算他離開，組織仍會依照同一使命存續。

 ▫ 目標是長期經營，不會為了套現被賣給大公司。

整段是在向使用者保證：如果你把基礎設施押在 Zig 上，長期風險相對較小。

5. Zig 在實務上的應用範圍

他展示許多「Zig in the wild」的案例，證明這不是玩具語言，而是已用在嚴肅場景：

- 低階系統與基礎設施：

 ▫ River Wayland 視窗管理器。

 ▫ Bun JavaScript runtime：作者特別提到 Zig 的低階記憶體控制與沒有隱藏控制流程，有利於極致效能調校。

- 作為其他高階語言的 native layer：

 ▫ Ziggler：幫 Elixir 撰寫 NIF，讓 Zig 與 Elixir 緊密整合。

 ▫ VFX 外掛：利用 Zig 寫特效 plug‑in，在大片量沙子特效中以「程式產生」資料、節省大量網路與儲存。

- 高效能應用與遊戲／圖形：

 ▫ 各種遊戲引擎、圖形工具包、物理引擎、PBR 渲染 demo。

 ▫ TigerBeetle：高效能金融帳務資料庫，完全用 Zig 撰寫。

- 資源受限環境：

 ▫ 無人商店的嵌入式系統，實際上線幾個月，報告為「零 bug」。

 ▫ microzig、BoksOS 等嵌入式與作業系統專案。

 ▫ WebAssembly 小型主機與遊戲 jam 中，Zig 在 wasm target 上相當受歡迎。

他的結論是：Zig 設計為「一般用途」，但在需要高可預測效能、低資源消耗、可控記憶體模型的場景特別出色。

6. 語言特色示範（A taste of Zig）

最後一段他挑了幾個語言與標準庫的特色舉例，來說明 Zig 的「簡單但可組合」設計。

幾個重點例子：

- 泛型容器設計（ArrayList）

 ▫ 用以型別為參數、回傳型別的 pattern 實作泛型結構。

 ▫ 語法簡單、沒有隱藏魔法，靠幾個 orthogonal 概念組合。

- inline for + 反射（dump 函式）

 ▫ 利用 ⁠@typeOf⁠ 取型別、⁠inline for⁠ 迭代 struct 欄位 metadata、⁠@field⁠ 存取實際欄位。

 ▫ 幾行就寫出泛型 debug dump 函式，執行時其實是編譯期間展開，沒有動態反射成本。

- AutoArrayHashMap / Set

 ▫ 內建「維持插入順序」的 hash map（類似 Python 3 dict），並自動根據 key 類型產生 hash/equal。

 ▫ 以 ⁠value = void⁠ 方式自然變成 set（零 byte value），不浪費空間。

 ▫ 測試框架會幫抓記憶體釋放遺漏，搭配 allocator 模型可偵測 leak。

- MultiArrayList + 資料導向設計

 ▫ 提供 struct‑of‑arrays 容器，改善 cache locality。

 ▫ 實作只用了 inline for 與反射，不需要語言層魔法，展示 Zig 在「表達高階資料結構但仍保持透明與可控」方面的能力。

 ▫ sort 介面用 strongly‑typed context 取代 C 的 ⁠void*⁠，同時保有彈性又型別安全。

- C 整合與跨編譯 demo

 ▫ 用 Zig 寫遊戲 prototype，直接 ⁠@cImport⁠ SDL、SDL_ttf、stb_image 等 C 函式庫。

 ▫ 在 native 環境下可連結系統已裝好的 library；若要 cross compile，則直接把這些 C 原始碼拉進專案一起編。

 ▫ 一個 build 腳本同時支援本機與 cross build，並可輸出可在 Windows 上執行的 exe。

 ▫ 首次編譯較久（因為要從 source 編 libc/SDL 等並做最佳化），之後靠快取重編非常快。

7. 總結訊息

最後他把整場 talk 收束為幾句話：

- Zig Software Foundation 是致力於提升軟體工程整體水準的非營利機構。

- 你就算不寫 Zig 程式碼，也能從更好的工具鏈、函式庫與生態系中獲益。

- 如果願意採用 Zig：

 ▫ 可以先從把 Zig 當 C/C++ 編譯器與 build system 開始，降低現有專案的維護成本；

 ▫ 進一步把某些元件用 Zig 重寫，在效能、除錯體驗、跨編譯等面向取得優勢。

- Zig 使用者與專案正在快速成長，而專案本身的組織結構（非營利）是為了支撐這個長期發展，不必被短期商業壓力扭曲。

整體來說，這支影片既是 Zig 的技術介紹，也是對其專案治理模式與長期承諾的說明。
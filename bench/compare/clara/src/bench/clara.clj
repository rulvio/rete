(ns bench.clara
  "The clara side of the rete comparison bench. See ../../README.md.

  Every scenario here has a counterpart in ../../rete.exs, and the two must do the same
  work. A scenario reports how many matches its counting query holds, and ../../report.exs
  refuses to print a ratio for a scenario whose counts disagree.

  The ruleset is written once and built twice, once over records and once over plain maps.
  Records are the clara idiom. Maps under :fact-type-fn are the closer mirror of a rete
  tagged tuple. Running both shows what the fact shape is worth."
  (:require [clara.rules :as r]
            [clara.rules.accumulators :as acc]
            [clara.rules.compiler :as com]
            [clara.rules.dsl :as dsl]
            [criterium.core :as crit]
            [clojure.java.io :as io]
            [clojure.string :as str])
  (:gen-class))

;; --- the facts ----------------------------------------------------------------------

(defrecord Customer [cid name])
(defrecord Order [cid amount])
(defrecord Flagged [cid amount])
(defrecord Paired [cid amount])
(defrecord Spend [cid total])
(defrecord Dormant [cid])
(defrecord A [x])
(defrecord B [x])
(defrecord C [x])
(defrecord D [x])
(defrecord Limit [limit])
(defrecord N [i])
(defrecord Out [rule x])

(defn customer-map [cid name] {:type :customer :cid cid :name name})
(defn order-map [cid amount] {:type :order :cid cid :amount amount})
(defn flagged-map [cid amount] {:type :flagged :cid cid :amount amount})
(defn paired-map [cid amount] {:type :paired :cid cid :amount amount})
(defn spend-map [cid total] {:type :spend :cid cid :total total})
(defn dormant-map [cid] {:type :dormant :cid cid})
(defn a-map [x] {:type :a :x x})
(defn b-map [x] {:type :b :x x})
(defn c-map [x] {:type :c :x x})
(defn d-map [x] {:type :d :x x})
(defn limit-map [limit] {:type :limit :limit limit})
(defn n-map [i] {:type :n :i i})
(defn out-map [rule x] {:type :out :rule rule :x x})

;; --- the generated fact types -------------------------------------------------------
;;
;; The rule-count scenario needs one fact type per rule, so that a fact reaches one alpha
;; and not all of them. 512 types are more than anybody writes out, so the record variant
;; evaluates 512 defrecord forms at start. This runs once, and no scenario times it.

(def ^:private rule-count 512)

(def ^:private generated-types
  (delay
    (binding [*ns* (find-ns 'bench.clara)]
      (vec (for [i (range 1 (inc rule-count))]
             (do (eval `(defrecord ~(symbol (str "F" i)) [~'x]))
                 (resolve (symbol (str "F" i)))))))))

(def ^:private generated-ctors
  (delay
    (vec (for [i (range 1 (inc rule-count))]
           @(resolve (symbol "bench.clara" (str "->F" i)))))))

;; --- building a ruleset --------------------------------------------------------------
;;
;; A production carries its left hand side as data and its right hand side as a form, and
;; `dsl/parse-rule*` quotes both for a macro to emit. Here there is no macro, so the result
;; is evaluated on the spot. That is the whole reason the ruleset can be built twice from
;; one piece of text.

(defn- rule
  [nm lhs rhs]
  (assoc (eval (dsl/parse-rule* lhs rhs nil {} nil)) :name nm))

(defn- query
  [nm params lhs]
  (assoc (eval (dsl/parse-query* params lhs {} nil)) :name nm))

(defn- lhs-cond
  "One condition, in the shape the running variant needs.

  A record carries its fields, so a constraint reads them by name. A map carries none, and
  `get-fields` returns nothing for a keyword type, so the fields are destructured out of the
  fact before the constraints run."
  [variant kind fields constraints]
  (let [t (get-in variant [:types kind])]
    (if (keyword? t)
      (into [t [{:keys (vec fields)}]] constraints)
      (into [t] constraints))))

(defn- ctor [variant kind] (get-in variant [:ctors kind]))

;; --- the rulesets ---------------------------------------------------------------------
;;
;; One ruleset per scenario, for the reason bench/run.exs gives: a shared ruleset would put
;; every scenario's facts through every other scenario's rules, and the measurement would be
;; of the fixture. Each one carries a counting query, which is how the two engines are held
;; to the same workload.

(defn- flag-rules [v]
  [(rule "flag"
         [(lhs-cond v :order '[cid amount] '[(> amount 100) (= ?cid cid) (= ?amt amount)])]
         `(r/insert! (~(ctor v :flagged) ~'?cid ~'?amt)))
   (query "count" [] [(lhs-cond v :flagged '[] [])])])

(defn- join-rules [v]
  [(rule "paired"
         [(lhs-cond v :customer '[cid] '[(= ?cid cid)])
          (lhs-cond v :order '[cid amount] '[(= ?cid cid) (= ?amt amount)])]
         `(r/insert! (~(ctor v :paired) ~'?cid ~'?amt)))
   (query "count" [] [(lhs-cond v :paired '[] [])])])

(defn- collection-rules [v]
  [(rule "spend"
         [(lhs-cond v :customer '[cid] '[(= ?cid cid)])
          (into ['?orders '<- `(acc/all) :from]
                [(lhs-cond v :order '[cid] '[(= ?cid cid)])])]
         `(r/insert! (~(ctor v :spend) ~'?cid (reduce + (map :amount ~'?orders)))))
   (query "count" [] [(lhs-cond v :spend '[] [])])])

(defn- negation-rules [v]
  [(rule "dormant"
         [(lhs-cond v :customer '[cid] '[(= ?cid cid)])
          [:not (lhs-cond v :order '[cid] '[(= ?cid cid)])]]
         `(r/insert! (~(ctor v :dormant) ~'?cid)))
   (query "count" [] [(lhs-cond v :dormant '[] [])])])

(defn- chain-rules [v]
  [(rule "b" [(lhs-cond v :a '[x] '[(= ?x x)])] `(r/insert! (~(ctor v :b) ~'?x)))
   (rule "c" [(lhs-cond v :b '[x] '[(= ?x x)])] `(r/insert! (~(ctor v :c) ~'?x)))
   (rule "d" [(lhs-cond v :c '[x] '[(= ?x x)])] `(r/insert! (~(ctor v :d) ~'?x)))
   (query "count" [] [(lhs-cond v :d '[] [])])])

(defn- cascade-rules [v]
  [(rule "step"
         [(lhs-cond v :limit '[limit] '[(= ?limit limit)])
          (lhs-cond v :n '[i] '[(= ?i i) (< i ?limit)])]
         `(r/insert! (~(ctor v :n) (inc ~'?i))))
   (query "count" [] [(lhs-cond v :n '[] [])])])

(defn- query-rules [v]
  (conj (flag-rules v)
        (query "flagged-for" [:?cid]
               [(lhs-cond v :flagged '[cid amount] '[(= ?cid cid) (= ?amt amount)])])))

(defn- generated-rules [v]
  (conj (vec (for [i (range 1 (inc rule-count))]
               (rule (str "r" i)
                     [(lhs-cond v [:generated i] '[x] '[(= ?x x)])]
                     `(r/insert! (~(ctor v :out) ~i ~'?x)))))
        (query "count" [] [(lhs-cond v :out '[] [])])))

;; The four rules a reader would actually write together. Only the build scenario uses this
;; one, because it is the only scenario that measures the rulebase rather than the firing.
(defn- full-rules [v]
  (conj (vec (remove #(= "count" (:name %))
                     (concat (flag-rules v) (join-rules v)
                             (collection-rules v) (negation-rules v))))
        (query "count" [] [(lhs-cond v :flagged '[] [])])))

;; --- the two variants -------------------------------------------------------------------

(def ^:private record-variant
  {:name "clara-record"
   :session-opts []
   :types {:customer Customer :order Order :flagged Flagged :paired Paired
           :spend Spend :dormant Dormant :a A :b B :c C :d D
           :limit Limit :n N :out Out}
   :ctors {:flagged `->Flagged :paired `->Paired :spend `->Spend :dormant `->Dormant
           :b `->B :c `->C :d `->D :n `->N :out `->Out}
   :facts {:customer ->Customer :order ->Order :a ->A :limit ->Limit :n ->N}})

(def ^:private map-variant
  {:name "clara-map"
   :session-opts [:fact-type-fn :type]
   :types {:customer :customer :order :order :flagged :flagged :paired :paired
           :spend :spend :dormant :dormant :a :a :b :b :c :c :d :d
           :limit :limit :n :n :out :out}
   :ctors {:flagged `flagged-map :paired `paired-map :spend `spend-map
           :dormant `dormant-map :b `b-map :c `c-map :d `d-map :n `n-map :out `out-map}
   :facts {:customer customer-map :order order-map :a a-map :limit limit-map :n n-map}})

;; A generated type is written `[:generated i]` in a condition, and resolved here, because
;; 512 entries would otherwise have to sit in the two maps above.
(defn- generated-type [variant i]
  (if (= :map (:kind variant))
    (keyword (str "f" i))
    (nth @generated-types (dec i))))

(defn- generated-ctor [variant i]
  (if (= :map (:kind variant))
    (fn [x] {:type (keyword (str "f" i)) :x x})
    (nth @generated-ctors (dec i))))

(defn- build
  "A session over `rules`, built for `variant`. `:cache false`, so a build is a build and
  not a memoized lookup of an earlier one.

  Every scenario but `build` calls this outside its timed thunk, so the expression cache is
  left at its default there. The `build` scenario passes `:compiler-cache false`, because a
  second build that reads a memoized expression is not the cost an application pays at
  start."
  ([variant rules] (build variant rules []))
  ([variant rules opts]
   (com/mk-session (into (into [rules :cache false] opts) (:session-opts variant)))))

(defn- fact [variant kind & args]
  (apply (get-in variant [:facts kind]) args))

(defn- tally [session] (count (r/query session "count")))

;; --- the harness --------------------------------------------------------------------
;;
;; Criterium does the warm-up, the sampling and the statistics. It is the standard tool on
;; the JVM, and ../../rete.exs hands the same job to Benchee. `quick-benchmark` warms the
;; JIT up for seconds and then takes a few samples, each a batch of runs.

(defn- measure [f]
  (let [result (crit/quick-benchmark* f {})
        mean (first (:mean result))]
    {:mean (* 1e3 mean)
     :rsd (/ (Math/sqrt (first (:variance result))) mean)}))

;; Criterium ends its warm-up only once the JVM stops loading classes. A scenario that calls
;; `eval` on every run loads new classes on every run, so that warm-up never ends. Such a
;; scenario takes this plain timer: warm up for as long as Criterium would, then time each
;; run on its own.
(def ^:private plain-warmup-ms 5000)
(def ^:private plain-runs 100)

(defn- now-ms [] (/ (System/nanoTime) 1e6))

(defn- measure-plain [f]
  (let [deadline (+ (now-ms) plain-warmup-ms)]
    (while (< (now-ms) deadline) (f)))
  (let [times (vec (for [_ (range plain-runs)]
                     (let [t0 (System/nanoTime)]
                       (f)
                       (/ (- (System/nanoTime) t0) 1e6))))
        mean (/ (reduce + times) plain-runs)
        variance (/ (reduce + (map #(Math/pow (- % mean) 2) times)) (dec plain-runs))]
    {:mean mean :rsd (/ (Math/sqrt variance) mean)}))

;; --- the scenarios ----------------------------------------------------------------------
;;
;; `:prepare` does everything that is not being measured and returns the thunk that is.
;; `:tally` reads what that thunk returned, and gives the number the two engines must agree
;; on. Nothing inside a thunk may depend on a previous call of it, because it runs many
;; times.

(def ^:private scenarios
  [;; Not a rules engine at all. A tight integer loop, written the same way on both sides,
   ;; whose job is to say how fast the process it ran in was going.
   ;;
   ;; The cross-engine ratio of this row means nothing: it compares two runtimes at
   ;; arithmetic, not two engines. What it is for is the comparison of one engine against
   ;; itself between runs. A process that lands on slow cores, or whose heap is not resident
   ;; yet, reads high here and high on every other row, and the run is to be repeated rather
   ;; than read.
   {:id "calibrate" :n 2000000
    :prepare (fn [_] #(reduce (fn [acc i] (+ acc (rem i 7))) 0 (range 1 2000001)))
    :tally (fn [total] total)}

   {:id "build" :n 0 :measure measure-plain
    :prepare (fn [v]
               (let [rules (full-rules v)]
                 #(build v rules [:compiler-cache false])))
    ;; A fresh session holds no match, so the count is 0 on both engines. The workload is
    ;; rule data to a live session.
    :tally (fn [_] 0)}

   {:id "insert-fire" :n 10000
    :prepare (fn [v]
               (let [session (build v (flag-rules v))
                     facts (vec (for [i (range 10000)] (fact v :order i 250)))]
                 #(-> session (r/insert-all facts) (r/fire-rules))))
    :tally tally}

   {:id "join-keyed" :n 5000
    :prepare (fn [v]
               (let [session (build v (join-rules v))
                     facts (vec (concat (for [i (range 5000)] (fact v :customer i "c"))
                                        (for [i (range 5000)] (fact v :order i 250))))]
                 #(-> session (r/insert-all facts) (r/fire-rules))))
    :tally tally}

   {:id "join-one-key" :n 5000
    :prepare (fn [v]
               (let [session (build v (join-rules v))
                     facts (vec (cons (fact v :customer 1 "c")
                                      (for [i (range 5000)] (fact v :order 1 i))))]
                 #(-> session (r/insert-all facts) (r/fire-rules))))
    :tally tally}

   {:id "collection" :n 1000
    :prepare (fn [v]
               (let [session (build v (collection-rules v))
                     facts (vec (concat (for [i (range 1000)] (fact v :customer i "c"))
                                        (for [i (range 1000) k (range 4)]
                                          (fact v :order i (+ 10 k)))))]
                 #(-> session (r/insert-all facts) (r/fire-rules))))
    :tally tally}

   {:id "negation" :n 2000
    :prepare (fn [v]
               (let [session (build v (negation-rules v))
                     customers (vec (for [i (range 2000)] (fact v :customer i "c")))
                     orders (vec (for [i (range 2000)] (fact v :order i 250)))]
                 ;; n conclusions suppressed and then released, which is the cost a
                 ;; negation node exists to pay.
                 #(-> session
                      (r/insert-all customers)
                      (r/fire-rules)
                      (r/insert-all orders)
                      (r/fire-rules)
                      (as-> s (apply r/retract s orders))
                      (r/fire-rules))))
    :tally tally}

   {:id "tms-retract" :n 2000
    :prepare (fn [v]
               (let [session (build v (chain-rules v))
                     facts (vec (for [i (range 2000)] (fact v :a i)))]
                 #(-> session
                      (r/insert-all facts)
                      (r/fire-rules)
                      (as-> s (apply r/retract s facts))
                      (r/fire-rules))))
    :tally tally}

   {:id "cascade" :n 2000
    :prepare (fn [v]
               (let [session (build v (cascade-rules v))
                     facts [(fact v :limit 2000) (fact v :n 0)]]
                 #(-> session (r/insert-all facts) (r/fire-rules))))
    :tally tally}

   {:id "query-param" :n 4000
    :prepare (fn [v]
               (let [loaded (-> (build v (query-rules v))
                                (r/insert-all (vec (for [i (range 4000)]
                                                     (fact v :order i 250))))
                                (r/fire-rules))]
                 ;; `count` forces the result, because clara answers a query with a lazy
                 ;; sequence and rete answers with a list. An unforced read measures nothing.
                 ;;
                 ;; 20,000 reads, because one read of one row is too cheap to time on its own.
                 #(reduce (fn [read _] (+ read (count (r/query loaded "flagged-for" :?cid 1))))
                          0
                          (range 20000))))
    ;; 20,000 reads of one row.
    :tally (fn [total] total)}

   {:id "rule-count" :n rule-count
    :prepare (fn [v]
               (let [session (build v (generated-rules v))
                     facts (vec (for [i (range 1 (inc rule-count))]
                                  ((generated-ctor v i) 1)))]
                 #(-> session (r/insert-all facts) (r/fire-rules))))
    :tally tally}])

;; --- running -----------------------------------------------------------------------------

(defn- with-generated-types
  "`lhs-cond` reads `[:generated i]` out of the variant's type map, which has no entry for
  it. This puts the entry there for the rule count the scenario asks for."
  [variant]
  (-> variant
      (assoc :kind (if (= "clara-map" (:name variant)) :map :record))
      (as-> v
            (reduce (fn [acc i]
                      (-> acc
                          (assoc-in [:types [:generated i]] (generated-type v i))
                          (assoc-in [:ctors :out] (:out (:ctors v)))))
                    v
                    (range 1 (inc rule-count))))))

(defn- run-variant [variant smoke?]
  (let [v (with-generated-types variant)]
    (vec (for [{:keys [id n prepare tally] :as scenario} scenarios]
           (let [thunk (prepare v)
                 count* (tally (thunk))]
             (println (format "  %-14s n=%-6d count=%d" id n count*))
             (flush)
             (merge {:engine (:name variant) :scenario id :n n :count count*}
                    (if smoke?
                      {:mean 0.0 :rsd 0.0}
                      ((:measure scenario measure) thunk))))))))

(defn- write-tsv [path rows]
  (io/make-parents path)
  (spit path
        (str (str/join "\t" ["engine" "scenario" "n" "count" "mean_ms" "rsd"]) "\n"
             (str/join "\n"
                       (for [{:keys [engine scenario n count mean rsd]} rows]
                         (str/join "\t" [engine scenario n count
                                         (format "%.3f" mean)
                                         (format "%.4f" rsd)])))
             "\n")))

(defn- jar-version
  "The version of a library, read off the pom.properties in the jar that was loaded. The
  version in deps.edn is the one asked for, and this is the one that ran."
  [group artifact]
  (if-let [props (io/resource (str "META-INF/maven/" group "/" artifact "/pom.properties"))]
    (with-open [in (io/input-stream props)]
      (.getProperty (doto (java.util.Properties.) (.load in)) "version"))
    "unknown"))

(defn- write-env
  "What this JVM is, asked of the JVM. `../report.exs` could shell out for a version
  instead, but on a machine with more than one Java installed the answer it got back would
  not be the one that ran. The flags and the collector are read the same way, because a
  bench whose heap settings are not recorded cannot be repeated."
  [path]
  (let [runtime (java.lang.management.ManagementFactory/getRuntimeMXBean)
        collectors (java.lang.management.ManagementFactory/getGarbageCollectorMXBeans)
        ;; Two arguments are noise. `-Djdk.attach` comes from JAVA_TOOL_OPTIONS in the
        ;; shell, and `-Dclojure.basis` is a cache path the CLI passes and nothing reads.
        noise ["-Djdk.attach" "-Dclojure.basis"]
        env [["clara-rules" (jar-version "com.github.gateless" "clara-rules")]
             ["criterium" (jar-version "criterium" "criterium")]
             ["clojure" (clojure-version)]
             ["java" (str (System/getProperty "java.runtime.version") " "
                          (System/getProperty "java.vendor.version"))]
             ["jvm" (str (System/getProperty "java.vm.name") ", "
                         (System/getProperty "os.arch"))]
             ["jvm options" (str/join " " (remove (fn [arg]
                                                    (some #(str/starts-with? arg %) noise))
                                                  (.getInputArguments runtime)))]
             ["collector" (str/join ", " (map #(.getName %) collectors))]
             ["heap" (str (quot (.maxMemory (Runtime/getRuntime)) (* 1024 1024)) " MB max")]]]
    (io/make-parents path)
    (spit path (str (str/join "\n" (map #(str/join "\t" %) env)) "\n"))))

;; One variant per process. Two of them in one JVM share their call sites, so whichever ran
;; second inherited the first one's inlining decisions and the two columns drifted toward
;; each other. `run.sh` starts a JVM for each.
(def ^:private variants
  {"record" record-variant
   "map" map-variant})

(defn -main [& args]
  (let [smoke? (boolean (some #{"--smoke"} args))
        [name* out] (remove #{"--smoke"} args)
        variant (or (get variants name*)
                    (throw (ex-info (str "unknown variant: " name*)
                                    {:known (keys variants)})))]
    (println (str "clara " name* ": " (if smoke? "smoke" "measuring")))
    (let [rows (run-variant variant smoke?)
          out (or out (str "../results/clara-" name* ".tsv"))]
      (write-tsv out rows)
      ;; Both variants write this, and the second overwrites the first. They run under the
      ;; same alias, so there is only one answer to record.
      (write-env "../results/clara-env.tsv")
      (println "wrote" out)
      (shutdown-agents))))

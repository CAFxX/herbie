#lang racket

(require "alternative.rkt")
(require "programs.rkt")
(require "matcher.rkt")
(require "points.rkt")
(require "common.rkt")
(require "syntax.rkt")
(require "config.rkt")
(require "localize-error.rkt")

(provide infer-splitpoints (struct-out sp))

(define (infer-splitpoints alts [axis #f])
  (debug "Finding splitpoints for:" alts #:from 'regime-changes #:depth 2)
  (let* ([options (map (curry option-on-expr alts)
		       (if axis (list axis) (exprs-to-branch-on alts)))]
	 [best-option (argmin (compose errors-score option-errors) options)]
	 [splitpoints (option-splitpoints best-option)]
	 [altns (used-alts splitpoints alts)]
	 [splitpoints* (coerce-indices splitpoints)])
    (debug #:from 'regimes "Found splitpoints:" splitpoints* ", with alts" altns)
    (list splitpoints* altns)))

(struct option (splitpoints errors) #:transparent
	#:methods gen:custom-write
        [(define (write-proc opt port mode)
           (display "#<option " port)
           (write (option-splitpoints opt) port)
           (display ">" port))])

;; Branch expression picking code

(define *bits-bad-threshold* (make-parameter 10))
;; How many clusters to attempt to cluster points into to determine
;; which axis is best.
(define *num-clusters* (make-parameter 5))
;; The number of trials of k-means scoring to use.
(define *num-scores* (make-parameter 3))

(define (pick-best-branch-expr context exprs)
  (let ([bad-points (for/list ([(p ex) (in-pcontext context)]
                               [e (errors (*start-prog*) context)]
                               #:when (> e (expt 2 (*bits-bad-threshold*))))
                      p)])
    (if (null? bad-points) (car exprs)
        (argmax (λ (branch-expr)
                  (cluster-rank (for/list ([bad-point bad-points])
                                  ((eval-prog `(λ ,(program-variables (*start-prog*))
                                                 ,branch-expr) mode:fl)
                                   bad-point))))
                exprs))))

;; Ranks a set of numbers by how well they group into clusters.
(define (cluster-rank xs)
  (for/sum ([idx (in-range (*num-scores*))])
    (k-means-score xs (*num-clusters*))))
;; Scores how well the given numbers can be clustered into
;; num-clusters clusters using k-means.
(define (k-means-score xs num-clusters)
  (let ([initial-means
         (for/list ([idx (in-range num-clusters)])
           (list-ref xs (random (length xs))))])
    (let loop ([means initial-means])
      (let* ([clustered-samples
              (for/list ([x xs])
                (cons x (argmin (λ (mean) (abs (- mean x))) means)))]
             [means* (filter
		      identity
		      (for/list ([mean means])
			(let ([cluster-xs (filter (compose (curry equal? mean) cdr) clustered-samples)])
			  (if (= 0 (length cluster-xs)) #f
			      (round (/ (apply + (map car cluster-xs))
					(length cluster-xs)))))))])
        (if (equal? means* means)
            (exact->inexact (/ (apply + (for/list ([sample clustered-samples])
                                          (sqr (- (car sample) (cdr sample)))))))
            (loop means*))))))

(define (exprs-to-branch-on alts)
  (define critexpr (critical-subexpression (*start-prog*)))
  (define var (pick-best-branch-expr
		(*pcontext*)
		(program-variables (alt-program (car alts)))))

  (if (and critexpr (not (equal? critexpr var)))
      (list critexpr var)
      (list var)))

(define (critical-subexpression prog)
  (define (loc-children loc subexpr)
    (map (compose (curry append loc)
		  list)
	 (range 1 (length subexpr))))
  (define (all-equal? items)
    (if (< (length items) 2) #t
	(and (equal? (car items) (cadr items)) (all-equal? (cdr items)))))
  (define (critical-child expr)
    (let ([var-locs
	   (let get-vars ([subexpr expr]
			  [cur-loc '()])
	     (cond [(list? subexpr)
		    (append-map get-vars (cdr subexpr)
				(loc-children cur-loc subexpr))]
		   [(constant? subexpr)
		    '()]
		   [(variable? subexpr)
		    (list (cons subexpr cur-loc))]))])
      (if (all-equal? (map car var-locs))
	  (caar var-locs)
	  (let get-subexpr ([subexpr expr] [vlocs var-locs])
	    (cond [(all-equal? (map cadr vlocs))
		   (get-subexpr (if (= 1 (cadar vlocs)) (cadr subexpr) (caddr subexpr))
				(for/list ([vloc vlocs])
				  (cons (car vloc) (cddr vloc))))]
		  [#t subexpr])))))
  (let* ([locs (localize-error prog)])
    (if (null? locs)
        #f
        (critical-child (location-get (car locs) prog)))))

;; =======================================================

(define basic-point-search (curry binary-search (λ (p1 p2)
						  (if (for/and ([val1 p1] [val2 p2])
							(> *epsilon-fraction* (abs (- val1 val2))))
						      p1
						      (for/list ([val1 p1] [val2 p2])
							(/ (+ val1 val2) 2))))))

(define (used-alts splitpoints all-alts)
  (let ([used-indices (remove-duplicates (map sp-cidx splitpoints))])
    (map (curry list-ref all-alts) used-indices)))

;; Takes a list of splitpoints, `splitpoints`, whose indices originally referred to some list of alts `alts`,
;; and changes their indices so that they are consecutive starting from zero, but all indicies that
;; previously matched still match.
(define (coerce-indices splitpoints)
  (let* ([used-indices (remove-duplicates (map sp-cidx splitpoints))]
	 [mappings (map cons used-indices (range (length used-indices)))])
    (map (λ (splitpoint)
	   (sp (cdr (assoc (sp-cidx splitpoint) mappings))
	       (sp-bexpr splitpoint)
	       (sp-point splitpoint)))
	 splitpoints)))

(define (option-on-expr alts expr)
  (match-let* ([vars (program-variables (*start-prog*))]
	       [`(,pts ,exs) (sort-context-on-expr (*pcontext*) expr vars)])
    (let* ([err-lsts (parameterize ([*pcontext* (mk-pcontext pts exs)])
		       (map alt-errors alts))]
	   [bit-err-lsts (map (curry map ulps->bits) err-lsts)]
	   [split-indices (err-lsts->split-indices bit-err-lsts)]
	   [split-points (sindices->spoints pts expr alts split-indices)])
      (option split-points (pick-errors split-points pts err-lsts vars)))))

;; Accepts a list of sindices in one indexed form and returns the
;; proper splitpoints in floath form.
(define (sindices->spoints points expr alts sindices)
  (define (eval-on-pt pt)
    (let* ([expr-prog `(λ ,(program-variables (alt-program (car alts)))
			 ,expr)]
	   [val-float ((eval-prog expr-prog mode:fl) pt)])
      (if (ordinary-float? val-float) val-float
	  ((eval-prog expr-prog mode:bf) pt))))

  (define (sidx->spoint sidx next-sidx)
    (let* ([alt1 (list-ref alts (si-cidx sidx))]
	   [alt2 (list-ref alts (si-cidx next-sidx))]
	   [p1 (eval-on-pt (list-ref points (si-pidx sidx)))]
	   [p2 (eval-on-pt (list-ref points (sub1 (si-pidx sidx))))]
	   [eps (* (- p1 p2) *epsilon-fraction*)]
	   [pred (λ (v)
		   (let* ([start-prog* (replace-subexpr (*start-prog*) expr v)]
			  [prog1* (replace-subexpr (alt-program alt1) expr v)]
			  [prog2* (replace-subexpr (alt-program alt2) expr v)]
			  [context
			   (parameterize ([*num-points* (*binary-search-test-points*)])
			     (prepare-points start-prog* (map (curryr cons sample-default)
							      (program-variables start-prog*))))])
		     (< (errors-score (errors prog1* context))
			(errors-score (errors prog2* context)))))])
      (debug #:from 'regimes "searching between" p1 "and" p2 "on" expr)
      (sp (si-cidx sidx) expr (binary-search-floats pred p1 p2 eps))))

  (append (map sidx->spoint
	       (take sindices (sub1 (length sindices)))
	       (drop sindices 1))
	  (list (let ([last-sidx (list-ref sindices (sub1 (length sindices)))])
		  (sp (si-cidx last-sidx)
		      expr
		      +inf.0)))))

(define (point-with-dim index point val)
  (map (λ (pval pindex) (if (= pindex index) val pval))
       point
       (range (length point))))

(define (pick-errors splitpoints pts err-lsts variables)
  (reverse
   (first-value
    (for/fold ([acc '()] [rest-splits splitpoints])
	([pt (in-list pts)]
	 [errs (flip-lists err-lsts)])
      (let* ([expr-prog `(λ ,variables ,(sp-bexpr (car rest-splits)))]
	     [float-val ((eval-prog expr-prog mode:fl) pt)]
	     [pt-val (if (ordinary-float? float-val) float-val
			 ((eval-prog expr-prog mode:bf) pt))])
	(if (or (<= pt-val (sp-point (car rest-splits)))
		(and (null? (cdr rest-splits)) (nan? pt-val)))
	    (if (nan? pt-val) (error "wat")
		(values (cons (list-ref errs (sp-cidx (car rest-splits)))
			      acc)
			rest-splits))
	    (values acc (cdr rest-splits))))))))

(define (with-entry idx lst item)
  (if (= idx 0)
      (cons item (cdr lst))
      (cons (car lst) (with-entry (sub1 idx) (cdr lst) item))))

;; Takes a vector of numbers, and returns the partial sum of those numbers.
;; For example, if your vector is #(1 4 6 3 8), then this returns #(1 5 11 14 22).
(define (partial-sum vec)
  (first-value
   (for/fold ([res (make-vector (vector-length vec))]
	      [cur-psum 0])
       ([(el idx) (in-indexed (in-vector vec))])
     (let ([new-psum (+ cur-psum el)])
       (vector-set! res idx new-psum)
       (values res new-psum)))))

;; Struct represeting a splitpoint
;; cidx = Candidate index: the index of the candidate program that should be used to the left of this splitpoint
;; bexpr = Branch Expression: The expression that this splitpoint should split on
;; point = Split Point: The point at which we should split.
(struct sp (cidx bexpr point) #:prefab)

;; Struct representing a splitindex
;; cidx = Candidate index: the index candidate program that should be used to the left of this splitindex
;; pidx = Point index: The index of the point to the left of which we should split.
(struct si (cidx pidx) #:prefab)

;; Struct representing a candidate set of splitpoints that we are considering.
;; cost = The total error in the region to the left of our rightmost splitpoint
;; splitpoints = The splitpoints we are considering in this candidate.
(struct cse (cost splitpoints) #:transparent)

;; Given error-lsts, returns a list of sp objects representing where the optimal splitpoints are.
(define (err-lsts->split-indices err-lsts)
  ;; We have num-candidates candidates, each of whom has error lists of length num-points.
  ;; We keep track of the partial sums of the error lists so that we can easily find the cost of regions.
  (define num-candidates (length err-lsts))
  (define num-points (length (car err-lsts)))
  (define min-weight num-points)

  (define psums (map (compose partial-sum list->vector) err-lsts))

  ;; Our intermediary data is a list of cse's,
  ;; where each cse represents the optimal splitindices after however many passes
  ;; if we only consider indices to the left of that cse's index.
  ;; Given one of these lists, this function tries to add another splitindices to each cse.
  (define (add-splitpoint sp-prev)
    ;; If there's not enough room to add another splitpoint, just pass the sp-prev along.
    (for/list ([point-idx (in-naturals)] [point-entry (in-list sp-prev)])
      ;; We take the CSE corresponding to the best choice of previous split point.
      ;; The default, not making a new split-point, gets a bonus of min-weight
      (let ([acost (- (cse-cost point-entry) min-weight)] [aest point-entry])
        (for ([prev-split-idx (in-naturals)] [prev-entry (in-list (take sp-prev point-idx))])
          ;; For each previous split point, we need the best candidate to fill the new regime
          (let ([best #f] [bcost #f])
            (for ([cidx (in-naturals)] [psum (in-list psums)])
              (let ([cost (- (vector-ref psum point-idx)
                             (vector-ref psum prev-split-idx))])
                (when (or (not best) (< cost bcost))
                  (set! bcost cost)
                  (set! best cidx))))
            (when (< (+ (cse-cost prev-entry) bcost) acost)
              (set! acost (+ (cse-cost prev-entry) bcost))
              (set! aest (cse acost (cons (si best (+ point-idx 1))
                                          (cse-splitpoints prev-entry)))))))
        aest)))

  ;; We get the initial set of cse's by, at every point-index,
  ;; accumulating the candidates that are the best we can do
  ;; by using only one candidate to the left of that point.
  (define initial
    (for/list ([point-idx (in-range num-points)])
      (argmin cse-cost
              ;; Consider all the candidates we could put in this region
              (map (λ (cand-idx cand-psums)
                      (let ([cost (vector-ref cand-psums point-idx)])
                        (cse cost
                             (list (si cand-idx (add1 point-idx))))))
                         (range num-candidates)
                         psums))))

  ;; We get the final splitpoints by applying add-splitpoints as many times as we want
  (define final
    (let loop ([prev initial])
      (let ([next (add-splitpoint prev)])
        (if (equal? prev next)
            next
            (loop next)))))

  ;; Extract the splitpoints from our data structure, and reverse it.
  (reverse (cse-splitpoints (last final))))

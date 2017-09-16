from libc.stdint cimport uint8_t, int8_t
from libc.stdlib cimport free
cimport cminimap2

cdef class Alignment:
	cdef int _ctg_len, _r_st, _r_en
	cdef int _q_st, _q_en
	cdef int _NM, _blen
	cdef int8_t _strand, _trans_strand
	cdef uint8_t _mapq, _is_primary
	cdef _ctg, _cigar # these are python objects

	def __cinit__(self, ctg, cl, cs, ce, strand, qs, qe, mapq, cigar, is_primary, blen, NM, trans_strand):
		self._ctg, self._ctg_len, self._r_st, self._r_en = ctg, cl, cs, ce
		self._strand, self._q_st, self._q_en = strand, qs, qe
		self._NM, self._blen = NM, blen
		self._mapq = mapq
		self._cigar = cigar
		self._is_primary = is_primary
		self._trans_strand = trans_strand

	@property
	def ctg(self): return self._ctg

	@property
	def ctg_len(self): return self._ctg_len

	@property
	def r_st(self): return self._r_st

	@property
	def r_en(self): return self._r_en

	@property
	def strand(self): return self.strand

	@property
	def trans_strand(self): return self.trans_strand

	@property
	def NM(self): return self._NM

	@property
	def is_primary(self): return (self._is_primary != 0)

	@property
	def q_st(self): return self._q_st

	@property
	def q_en(self): return self._q_en

	@property
	def mapq(self): return self._mapq

	@property
	def cigar(self): return self._cigar

	@property
	def cigar_str(self):
		return "".join(map(lambda x: str(x[0]) + 'MIDNSH'[x[1]], self._cigar))

	def __str__(self):
		if self._strand > 0: strand = '+'
		elif self._strand < 0: strand = '-'
		else: strand = '?'
		if self._is_primary != 0: tp = 'tp:A:P'
		else: tp = 'tp:A:S'
		return "\t".join([str(self._q_st), str(self._q_en), strand, self._ctg, str(self._ctg_len), str(self._r_st), str(self._r_en),
				str(self._blen - self._NM), str(self._blen), str(self._mapq), "NM:i:" + str(self._NM), tp, "cg:Z:" + self.cigar_str])

cdef class ThreadBuffer:
	cdef cminimap2.mm_tbuf_t *_b

	def __cinit__(self):
		self._b = cminimap2.mm_tbuf_init()

	def __dealloc__(self):
		cminimap2.mm_tbuf_destroy(self._b)

cdef class Aligner:
	cdef cminimap2.mm_idx_t *_idx
	cdef cminimap2.mm_idxopt_t idx_opt
	cdef cminimap2.mm_mapopt_t map_opt

	def __cinit__(self, fn_idx_in, preset=None, k=None, w=None, min_cnt=None, min_chain_score=None, min_dp_score=None, bw=None, best_n=None, n_threads=3, fn_idx_out=None):
		cminimap2.mm_set_opt(NULL, &self.idx_opt, &self.map_opt) # set the default options
		if preset is not None:
			cminimap2.mm_set_opt(preset, &self.idx_opt, &self.map_opt) # apply preset
		self.map_opt.flag |= 4 # always perform alignment
		self.idx_opt.batch_size = 0x7fffffffffffffffL # always build a uni-part index
		if k is not None: self.idx_opt.k = k
		if w is not None: self.idx_opt.w = w
		if min_cnt is not None: self.map_opt.min_cnt = min_cnt
		if min_chain_score is not None: self.map_opt.min_chain_score = min_chain_score
		if min_dp_score is not None: self.map_opt.min_dp_max = min_dp_score
		if bw is not None: self.map_opt.bw = bw
		if best_n is not None: self.best_n = best_n

		cdef cminimap2.mm_idx_reader_t *r;
		if fn_idx_out is None:
			r = cminimap2.mm_idx_reader_open(fn_idx_in, &self.idx_opt, NULL)
		else:
			r = cminimap2.mm_idx_reader_open(fn_idx_in, &self.idx_opt, fn_idx_out)
		if r is not NULL:
			self._idx = cminimap2.mm_idx_reader_read(r, n_threads) # NB: ONLY read the first part
			cminimap2.mm_idx_reader_close(r)
			cminimap2.mm_mapopt_update(&self.map_opt, self._idx)
	
	def __dealloc__(self):
		if self._idx is not NULL:
			cminimap2.mm_idx_destroy(self._idx)

	def map(self, seq, buf=None):
		cdef cminimap2.mm_reg1_t *regs
		cdef cminimap2.mm_hitpy_t h
		cdef ThreadBuffer b
		cdef int n_regs

		if self._idx is NULL: return None
		if buf is None: b = ThreadBuffer()
		else: b = buf
		regs = cminimap2.mm_map(self._idx, len(seq), seq, &n_regs, b._b, &self.map_opt, NULL)

		for i in range(n_regs):
			cminimap2.mm_reg2hitpy(self._idx, &regs[i], &h)
			cigar = []
			for k in range(h.n_cigar32):
				c = h.cigar32[k]
				cigar.append([c>>4, c&0xf])
			yield Alignment(h.ctg, h.ctg_len, h.ctg_start, h.ctg_end, h.strand, h.qry_start, h.qry_end, h.mapq, cigar, h.is_primary, h.blen, h.NM, h.trans_strand)
			cminimap2.mm_free_reg1(&regs[i])
		free(regs)

#cython: embedsignature=True
cimport numpy
from libc.stddef cimport ptrdiff_t
from libc.string cimport strcpy
from libc.stdlib cimport free
import numpy

numpy.import_array()

try:
    basestring  # attempt to evaluate basestring
    def isstr(s):
        return isinstance(s, basestring)
except NameError:
    def isstr(s):
        return isinstance(s, str)


cdef extern from "bigfile.c":
    struct CBigFile "BigFile":
        char * basename

    struct CBigBlock "BigBlock":
        char * dtype
        int nmemb
        char * basename
        size_t size
        int Nfile
        unsigned int * fchecksum; 
        int dirty
        CBigAttrSet * attrset;

    struct CBigBlockPtr "BigBlockPtr":
        pass

    struct CBigArray "BigArray":
        int ndim
        char * dtype
        ptrdiff_t * dims
        ptrdiff_t * strides
        size_t size
        void * data

    struct CBigAttr "BigAttr":
        int nmemb
        char dtype[8]
        char * name
        char * data

    struct CBigAttrSet "BigAttrSet":
        pass

    char * big_file_get_error_message() nogil
    void big_file_set_buffer_size(size_t bytes) nogil
    int big_block_open(CBigBlock * bb, char * basename) nogil
    int big_block_grow(CBigBlock * bb, int Nfilegrow, size_t fsize[]) nogil
    int big_block_clear_checksum(CBigBlock * bb) nogil
    int big_block_create(CBigBlock * bb, char * basename, char * dtype, int nmemb, int Nfile, size_t fsize[]) nogil
    int big_block_close(CBigBlock * block) nogil
    int big_block_flush(CBigBlock * block) nogil
    void big_block_set_dirty(CBigBlock * block, int value) nogil
    void big_attrset_set_dirty(CBigAttrSet * attrset, int value) nogil
    int big_block_seek(CBigBlock * bb, CBigBlockPtr * ptr, ptrdiff_t offset) nogil
    int big_block_seek_rel(CBigBlock * bb, CBigBlockPtr * ptr, ptrdiff_t rel) nogil
    int big_block_read(CBigBlock * bb, CBigBlockPtr * ptr, CBigArray * array) nogil
    int big_block_write(CBigBlock * bb, CBigBlockPtr * ptr, CBigArray * array) nogil
    int big_block_set_attr(CBigBlock * block, char * attrname, void * data, char * dtype, int nmemb) nogil
    int big_block_remove_attr(CBigBlock * block, char * attrname) nogil
    int big_block_get_attr(CBigBlock * block, char * attrname, void * data, char * dtype, int nmemb) nogil
    CBigAttr * big_block_lookup_attr(CBigBlock * block, char * attrname) nogil
    CBigAttr * big_block_list_attrs(CBigBlock * block, size_t * count) nogil
    int big_array_init(CBigArray * array, void * buf, char * dtype, int ndim, size_t dims[], ptrdiff_t strides[]) nogil

    int big_file_open_block(CBigFile * bf, CBigBlock * block, char * blockname) nogil
    int big_file_create_block(CBigFile * bf, CBigBlock * block, char * blockname, char * dtype, int nmemb, int Nfile, size_t fsize[]) nogil
    int big_file_open(CBigFile * bf, char * basename) nogil
    int big_file_list(CBigFile * bf, char *** list, int * N) nogil
    int big_file_create(CBigFile * bf, char * basename) nogil
    int big_file_close(CBigFile * bf) nogil

def set_buffer_size(bytes):
    big_file_set_buffer_size(bytes)

class Error(Exception):
    def __init__(self, msg=None):
        cdef char * errmsg = big_file_get_error_message()
        if errmsg == NULL:
            errmsg = "Unknown error (could have been swallowed due to poor threading support)"
        if msg is None:
            msg = errmsg
        Exception.__init__(self, msg)

class FileClosedError(Exception):
    def __init__(self, bigfile):
        Exception.__init__(self, "File is closed")

class ColumnClosedError(Exception):
    def __init__(self, bigblock):
        Exception.__init__(self, "Block is closed")

cdef class FileLowLevelAPI:
    cdef CBigFile bf
    cdef int closed

    def __cinit__(self):
        self.closed = True
    def __init__(self, filename, create=False):
        """ if create is True, create the file if it is nonexisting"""
        filename = filename.encode()
        cdef char * filenameptr = filename
        if create:
            with nogil:
                rt = big_file_create(&self.bf, filenameptr)
        else:
            with nogil:
                rt = big_file_open(&self.bf, filenameptr)
        if rt != 0:
            raise Error()
        self.closed = False

    def __dealloc__(self):
        if not self.closed:
            big_file_close(&self.bf)

    def _check_closed(self):
        if self.closed:
            raise FileClosedError(self)

    property basename:
        def __get__(self):
            self._check_closed();
            return '%s' % self.bf.basename.decode()

    def list_blocks(self):
        cdef char ** list
        cdef int N
        self._check_closed();
        with nogil:
            big_file_list(&self.bf, &list, &N)
        try:
            return sorted([str(list[i].decode()) for i in range(N)])
        finally:
            for i in range(N):
                free(list[i])
            free(list)
        return []

    def close(self):
        self.closed = True
        with nogil:
            rt = big_file_close(&self.bf)
        if rt != 0:
            raise Error()

cdef class AttrSet:
    cdef readonly ColumnLowLevelAPI bb

    def keys(self):
        self.bb._check_closed()
        cdef size_t count
        cdef CBigAttr * list
        list = big_block_list_attrs(&self.bb.bb, &count)
        return sorted([str(list[i].name.decode()) for i in range(count)])

    def __init__(self, ColumnLowLevelAPI bb):
        self.bb = bb

    def __iter__(self):
        return iter(self.keys())

    def __contains__(self, name):
        name = name.encode()
        self.bb._check_closed()
        cdef CBigAttr * attr = big_block_lookup_attr(&self.bb.bb, name)
        if attr == NULL:
            return False
        return True

    def __getitem__(self, name):
        name = name.encode()
        self.bb._check_closed()

        cdef CBigAttr * attr = big_block_lookup_attr(&self.bb.bb, name)
        if attr == NULL:
            raise KeyError("attr not found")
        cdef numpy.ndarray result = numpy.empty(attr[0].nmemb, attr[0].dtype)
        if(0 != big_block_get_attr(&self.bb.bb, name, result.data, attr[0].dtype,
            attr[0].nmemb)):
            raise Error()
        if attr[0].dtype[1] == 'S':
            return [i.tostring().decode() for i in result]
        if attr[0].dtype[1] == 'a':
            return result.tostring().decode()
        return result

    def __delitem__(self, name):
        name = name.encode()
        self.bb._check_closed()

        cdef CBigAttr * attr = big_block_lookup_attr(&self.bb.bb, name)
        if attr == NULL:
            raise KeyError("attr not found")
        big_block_remove_attr(&self.bb.bb, name)

    def __setitem__(self, name, value):
        name = name.encode()

        self.bb._check_closed()


        if isstr(value):
            dtype = b'a1'
            value = numpy.array(str(value).encode()).ravel().view(dtype='S1').ravel()
        else:
            value = numpy.array(value).ravel()

            if value.dtype.char == 'U':
                value = numpy.array([i.encode() for i in value])

            if value.dtype.hasobject:
                raise ValueError("Attribute value of object type is not supported; serialize it first")

            dtype = value.dtype.base.str.encode()

        cdef numpy.ndarray buf = value

        if(0 != big_block_set_attr(&self.bb.bb, name, buf.data, 
                dtype,
                buf.shape[0])):
            raise Error();

    def __repr__(self):
        t = ("<BigAttr (%s)>" %
            ','.join([ "%s=%s" %
                       (str(key), repr(self[key]))
                for key in self]))
        return t

cdef class ColumnLowLevelAPI:
    cdef CBigBlock bb
    cdef readonly int closed
    cdef public comm

    property size:
        def __get__(self):
            self._check_closed()
            return self.bb.size

    property dtype:
        def __get__(self):
            self._check_closed()
            return numpy.dtype((self.bb.dtype, self.bb.nmemb))
    property attrs:
        def __get__(self):
            self._check_closed()
            return AttrSet(self)
    property Nfile:
        def __get__(self):
            self._check_closed()
            return self.bb.Nfile

    def _check_closed(self):
        if self.closed:
            raise ColumnClosedError(self)

    def __cinit__(self):
        self.closed = True
        self.comm = None

    def __init__(self):
        pass

    def __enter__(self):
        self._check_closed()
        return self

    def __exit__(self, type, value, tb):
        self.close()

    def open(self, FileLowLevelAPI f, blockname):
        f._check_closed()
        blockname = blockname.encode()
        cdef char * blocknameptr = blockname
        with nogil:
            rt = big_file_open_block(&f.bf, &self.bb, blocknameptr)
        if rt != 0:
            raise Error()
        self.closed = False

    def grow(self, numpy.intp_t size, numpy.intp_t Nfile=1):
        """
            Increase the size of the column by size.
        """
        self._check_closed()
        cdef numpy.ndarray fsize

        if Nfile < 0:
            raise ValueError("Cannot create negative number of files.")
        if Nfile == 0 and size != 0:
            raise ValueError("Cannot create zero files for non-zero number of items.")

        fsize = numpy.empty(dtype='intp', shape=Nfile)
        fsize[:] = (numpy.arange(Nfile) + 1) * size // Nfile \
                 - (numpy.arange(Nfile)) * size // Nfile

        with nogil:
            rt = big_block_grow(&self.bb, Nfile, <size_t*>fsize.data)
        if rt != 0:
            raise Error()

        self.closed = False

    def create(self, FileLowLevelAPI f, blockname, dtype=None, size=None, numpy.intp_t Nfile=1):
        f._check_closed()

        # need to hold the reference
        blockname = blockname.encode()

        cdef numpy.ndarray fsize
        cdef numpy.intp_t items
        cdef char * dtypeptr
        cdef char * blocknameptr

        blocknameptr = blockname
        if dtype is None:
            with nogil:
                rt = big_file_create_block(&f.bf, &self.bb, blocknameptr, NULL,
                        0, 0, NULL)
            if rt != 0:
                raise Error()

        else:
            if Nfile < 0:
                raise ValueError("Cannot create negative number of files.")
            if Nfile == 0 and size != 0:
                raise ValueError("Cannot create zero files for non-zero number of items.")
            dtype = numpy.dtype(dtype)
            assert len(dtype.shape) <= 1
            if len(dtype.shape) == 0:
                items = 1
            else:
                items = dtype.shape[0]
            fsize = numpy.empty(dtype='intp', shape=Nfile)
            fsize[:] = (numpy.arange(Nfile) + 1) * size // Nfile \
                     - (numpy.arange(Nfile)) * size // Nfile
            dtype2 = dtype.base.str.encode()
            dtypeptr = dtype2
            with nogil:
                rt = big_file_create_block(&f.bf, &self.bb, blocknameptr,
                    dtypeptr,
                    items, Nfile, <size_t*> fsize.data)
            if rt != 0:
                raise Error()

        self.closed = False

    def clear_checksum(self):
        """ reset the checksum to zero for freshly overwriting the data set
        """
        self._check_closed()
        big_block_clear_checksum(&self.bb)

    def write(self, numpy.intp_t start, numpy.ndarray buf):
        """ write at offset `start' a chunk of data inf buf.

            no checking is performed. assuming buf is of the correct dtype.
        """
        self._check_closed()
        cdef CBigArray array
        cdef CBigBlockPtr ptr

        big_array_init(&array, buf.data, buf.dtype.str.encode(), 
                buf.ndim, 
                <size_t *> buf.shape,
                <ptrdiff_t *> buf.strides)
        with nogil:
            rt = big_block_seek(&self.bb, &ptr, start)
        if rt != 0:
            raise Error()

        with nogil:
            rt = big_block_write(&self.bb, &ptr, &array)
        if rt != 0:
            raise Error()

    def __getitem__(self, sl):
        """ returns a copy of data, sl can be a slice or a scalar
        """
        self._check_closed()
        if isinstance(sl, slice):
            start, end, stop = sl.indices(self.size)
            if stop != 1:
                raise ValueError('must request a contiguous chunk')
            return self.read(start, end-start)
        elif sl is Ellipsis:
            return self[:]
        elif numpy.isscalar(sl):
            sl = slice(sl, sl + 1)
            return self[sl][0]
        else:
            raise TypeError('Expecting a slice or a scalar, got a `%s`' %
                    str(type(sl)))

    def read(self, numpy.intp_t start, numpy.intp_t length, out=None):
        """ read from offset `start' a chunk of data of length `length', 
            into array `out'.

            out shall match length and self.dtype

            returns out, or a newly allocated array of out is None.
        """
        self._check_closed()
        cdef numpy.ndarray result 
        cdef CBigArray array
        cdef CBigBlockPtr ptr
        cdef int i
        if length == -1:
            length = self.size - start
        if length + start > self.size:
            length = self.size - start
        if out is None:
            result = numpy.empty(dtype=self.dtype, shape=length)
        else:
            result = out
            if result.shape[0] != length:
                raise ValueError("output array length mismatches with the request")
            if result.dtype.base.itemsize != self.dtype.base.itemsize:
                raise ValueError("output array type mismatches with the block")

        big_array_init(&array, result.data, self.bb.dtype, 
                result.ndim, 
                <size_t *> result.shape,
                <ptrdiff_t *> result.strides)

        with nogil:
            rt = big_block_seek(&self.bb, &ptr, start)
        if rt != 0:
            raise Error()

        with nogil:
            rt = big_block_read(&self.bb, &ptr, &array)
        if rt != 0:
            raise Error()
        return result

    def _flush(self):
        self._check_closed()
        with nogil:
            rt = big_block_flush(&self.bb)
        if rt != 0:
            raise Error()

    def _MPI_flush(self):
        self._check_closed()
        comm = self.comm
        cdef unsigned int Nfile = self.bb.Nfile
        cdef unsigned int[:] fchecksum
        cdef unsigned int[:] fchecksum2

        dirty = any(comm.allgather(self.bb.dirty))

        if Nfile > 0:
            fchecksum = <unsigned int[:Nfile]>self.bb.fchecksum
            fchecksum2 = fchecksum.copy()
            comm.Allreduce(fchecksum, fchecksum2)
            for i in range(Nfile):
                fchecksum[i] = fchecksum2[i]

        if comm.rank == 0:
            big_block_set_dirty(&self.bb, dirty);
        else:
            big_block_set_dirty(&self.bb, 0);
            big_attrset_set_dirty(self.bb.attrset, 0);

        with nogil:
            rt = big_block_flush(&self.bb)
        if rt != 0:
            raise Error()
        comm.barrier()

    def _close(self):
        if self.closed: return
        self.closed = True

        with nogil:
            rt = big_block_close(&self.bb)
        if rt != 0:
            raise Error()

    def _MPI_close(self):
        if self.closed: return
        # flush the other ranks
        self._MPI_flush()

        self.closed = True

        with nogil:
            rt = big_block_close(&self.bb)
        if rt != 0:
            raise Error()

        comm = self.comm
        comm.barrier()

    def __dealloc__(self):
        if self.closed: return
        self.close()

    def __repr__(self):
        if self.closed:
            return "<CBigBlock: Closed>"
        if self.bb.dtype == b'####':
            return "<CBigBlock: %s>" % self.bb.basename

        return "<CBigBlock: %s dtype=%s, size=%d>" % (self.bb.basename,
                self.dtype, self.size)

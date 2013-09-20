#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "perliol.h"

/* Copied from perlio.c */

#define PerlIO_lockcnt(f) (((PerlIOl*)(f))->head->flags)

static void
S_lockcnt_dec(pTHX_ const void* f)
{
	PerlIO_lockcnt((PerlIO*)f)--;
}

/* call the signal handler, and if that handler happens to clear
 * this handle, free what we can and return true */

static bool
S_perlio_async_run(pTHX_ PerlIO* f) {
	ENTER;
	SAVEDESTRUCTOR_X(S_lockcnt_dec, (void*)f);
	PerlIO_lockcnt(f)++;
	PERL_ASYNC_CHECK();
	if ( !(PerlIOBase(f)->flags & PERLIO_F_CLEARED) ) {
		LEAVE;
		return 0;
	}
	/* we've just run some perl-level code that could have done
	 * anything, including closing the file or clearing this layer.
	 * If so, free any lower layers that have already been
	 * cleared, then return an error. */
	while (PerlIOValid(f) &&
			(PerlIOBase(f)->flags & PERLIO_F_CLEARED))
	{
		const PerlIOl *l = *f;
		*f = l->next;
		Safefree(l);
	}
	LEAVE;
	return 1;
}

typedef struct {
    struct _PerlIO base;        /* The generic part */
    int fd;                     /* UNIX like file descriptor */
    int oflags;                 /* open/fcntl flags */
} PerlIOUnix;

/* End of copy */

#undef unix

typedef struct PerlIOTimeout {
	PerlIOUnix unix;
	NV timeout;
} PerlIOTimeout;

static int make_nonblock(int fd) {
	int flags = fcntl(fd, F_GETFL);
	flags |= O_NONBLOCK;
	return fcntl(fd, F_SETFL, flags) == 0;
}

static IV PerlIOTimeout_pushed(pTHX_ PerlIO *f, const char *mode, SV *arg, PerlIO_funcs *tab) {
	PerlIO* next = PerlIONext(f);
	if (!PerlIOValid(f)) {
		SETERRNO(EBADF, SS_IVCHAN);
		return -1;
	}
	else if (PerlIOValid(PerlIONext(f))) {
		SETERRNO(EINVAL, LIB_INVARG);
		return -1;
	}
	PerlIOBase_pushed(aTHX_ f, mode, arg, tab);
	return 0;
}

static PerlIO* PerlIOTimeout_open(pTHX_ PerlIO_funcs *self, PerlIO_list_t *layers, IV n, const char *mode, int fd, int imode, int perm, PerlIO *old, int narg, SV **args) {
	PerlIO* ret = PerlIOUnix_open(aTHX_ self, layers, n, mode, fd, imode, perm, old, narg, args);
	if (PerlIOValid(ret)) {
		PerlIOTimeout * info = PerlIOSelf(ret, PerlIOTimeout);
		info->timeout = SvIV(PerlIOArg);
		if (!make_nonblock(info->unix.fd)) {
			PerlIO_close(ret);
			return NULL;
		}
	}
	return ret;
}

static SSize_t PerlIOTimeout_read(pTHX_ PerlIO *f, void *vbuf, Size_t count) {
	int fd;
	PerlIOTimeout* info = PerlIOSelf(f, PerlIOTimeout);
	if (PerlIO_lockcnt(f)) /* in use: abort ungracefully */
		return -1;
	fd = info->unix.fd;
	if (!(PerlIOBase(f)->flags & PERLIO_F_CANREAD) ||
		 PerlIOBase(f)->flags & (PERLIO_F_EOF|PERLIO_F_ERROR)) {
		return 0;
	}
	while (1) {
		const SSize_t len = PerlLIO_read(fd, vbuf, count);
		if (len >= 0) {
			if (len == 0 && count != 0) {
				eof:
				PerlIOBase(f)->flags |= PERLIO_F_EOF;
				return 0;
			}
			return len;
		}
		else if (errno == EINTR) {
			if (PL_sig_pending && S_perlio_async_run(aTHX_ f))
				return -1;
		}
		else if (errno == EAGAIN) {
			fd_set rfds;
			struct timeval tv;
			int success;
			FD_ZERO(&rfds);
			FD_SET(fd, &rfds);
			tv.tv_sec = (int)info->timeout;
			tv.tv_usec = 1000000 * (info->timeout - tv.tv_sec);
			retry:
			success = select(fd + 1, &rfds, NULL, NULL, &tv);
			if (success)
				continue;
			else if (success == -1) {
				if (errno == EINTR) {
					if (PL_sig_pending && S_perlio_async_run(aTHX_ f))
						return -1;
					goto retry;
				}
				else
					goto error;
			}
			else if (success == 0) {
				goto eof;
			}
		}
		else {
			error:
			PerlIOBase(f)->flags |= PERLIO_F_ERROR;
			return -1;
		}
	}
}

static SSize_t PerlIOTimeout_write(pTHX_ PerlIO *f, const void *vbuf, Size_t count) {
	return -1;
}

const PerlIO_funcs PerlIO_timeout = {
	sizeof(PerlIO_funcs),
	"timeout",
	sizeof(PerlIOTimeout),
	PERLIO_K_RAW,
	PerlIOTimeout_pushed,
	PerlIOBase_popped,
	PerlIOTimeout_open,
	PerlIOBase_binmode,		 /* binmode */
	NULL,
	PerlIOUnix_fileno,
	PerlIOUnix_dup,
	PerlIOTimeout_read,
	PerlIOBase_unread,
	PerlIOTimeout_write,
	PerlIOUnix_seek,
	PerlIOUnix_tell,
	PerlIOUnix_close,
	PerlIOBase_noop_ok,		 /* flush */
	PerlIOBase_noop_fail,	   /* fill */
	PerlIOBase_eof,
	PerlIOBase_error,
	PerlIOBase_clearerr,
	PerlIOBase_setlinebuf,
	NULL,					   /* get_base */
	NULL,					   /* get_bufsiz */
	NULL,					   /* get_ptr */
	NULL,					   /* get_cnt */
	NULL,					   /* set_ptrcnt */
};


MODULE = PerlIO::timeout				PACKAGE = PerlIO::timeout

BOOT:
	PerlIO_define_layer(aTHX_ (PerlIO_funcs*)&PerlIO_timeout);

#ifndef NECRO_KTLS_SHIM_H
#define NECRO_KTLS_SHIM_H

#include <openssl/ssl.h>
#include <openssl/bio.h>
#include <openssl/err.h>

static inline int necro_bio_get_ktls_send(BIO *b) {
    return BIO_get_ktls_send(b) > 0;
}

static inline int necro_bio_get_ktls_recv(BIO *b) {
    return BIO_get_ktls_recv(b) > 0;
}

static inline unsigned long necro_ssl_op_enable_ktls(void) {
    return SSL_OP_ENABLE_KTLS;
}

#endif

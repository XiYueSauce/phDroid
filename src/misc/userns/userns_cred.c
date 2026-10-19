// SPDX-License-Identifier: GPL-2.0-only
/*
 * Credential side of installing a fake user namespace. Mirrors
 * set_cred_user_ns() from kernel/user_namespace.c: the full capability set goes
 * to the new namespace, where cap_capable() honours it, while every check
 * against the initial namespace fails because of the level comparison.
 */

#include <linux/sched.h>
#include <linux/cred.h>
#include <linux/capability.h>
#include <linux/securebits.h>
#include <linux/key.h>

#include "misc.h"
#include "misc_ksym.h"
#include "userns.h"

void droid_lkm_userns_install_cred(struct cred *new, struct droid_lkm_userns *u)
{
	new->securebits = SECUREBITS_DEFAULT;
	new->cap_inheritable = CAP_EMPTY_SET;
	new->cap_permitted = CAP_FULL_SET;
	new->cap_effective = CAP_FULL_SET;
	new->cap_ambient = CAP_EMPTY_SET;
	new->cap_bset = CAP_FULL_SET;
#ifdef CONFIG_KEYS
	if (new->request_key_auth) {
		droid_lkm_misc_ks.key_put(new->request_key_auth);
		new->request_key_auth = NULL;
	}
#endif
	new->user_ns = &u->uns;
}

int droid_lkm_userns_install_current(struct droid_lkm_userns *u)
{
	struct cred *new;

	new = droid_lkm_misc_ks.prepare_creds();
	if (!new)
		return -ENOMEM;

	droid_lkm_userns_install_cred(new, u);
	droid_lkm_misc_ks.commit_creds(new);

	return 0;
}

#!/usr/bin/perl

use strict;
use warnings;
use Modern::Perl;

use Koha::Plugins;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner;

Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner->new->run;

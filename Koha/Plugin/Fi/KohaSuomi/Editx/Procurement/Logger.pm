#!/usr/bin/perl
package Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Logger;

use Modern::Perl;

use File::Path qw(make_path);
use POSIX qw(strftime);

use Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog;

my $singleton;
my $log_folder;
my $error_log_path;
my $transaction_log_path;

sub new {
    my ( $class, $requested_log_folder ) = @_;

    if ( !$log_folder && $requested_log_folder ) {
        $log_folder = $requested_log_folder;
        $log_folder =~ s{/+\z}{};
        if ($log_folder) {
            make_path($log_folder) unless -d $log_folder;
            $transaction_log_path = "$log_folder/transaction.log";
            $error_log_path       = "$log_folder/error.log";
        }
    }

    $singleton ||= bless {}, $class;

    return $singleton;
}

sub debug {
    my ( $self, $message, $use_echo ) = @_;

    return $self->_log_level( 'debug', $message, $use_echo );
}

sub info {
    my ( $self, $message, $use_echo ) = @_;

    return $self->_log_level( 'info', $message, $use_echo );
}

sub notice {
    my ( $self, $message, $use_echo ) = @_;

    return $self->_log_level( 'notice', $message, $use_echo );
}

sub warn {
    my ( $self, $message, $use_echo ) = @_;

    return $self->_log_level( 'warn', $message, $use_echo );
}

sub error {
    my ( $self, $message, $use_echo ) = @_;

    return $self->_log_level( 'error', $message, $use_echo );
}

sub log {
    my ( $self, $message, $use_echo ) = @_;

    return $self->info( $message, $use_echo );
}

sub logError {
    my ( $self, $message, $use_echo ) = @_;

    return $self->error( $message, $use_echo );
}

sub _log_level {
    my ( $self, $level, $message, $use_echo ) = @_;

    return 1 unless defined $message && length $message;

    Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->log(
        {
            level     => $level,
            message   => $message,
            component => 'procurement',
        }
    );

    $self->_write_legacy_file( $level, $message );

    if ($use_echo) {
        $level =~ /\A(?:error|warn)\z/
            ? CORE::warn "$message\n"
            : print "$message\n";
    }

    return 1;
}

sub _write_legacy_file {
    my ( $self, $level, $message ) = @_;

    my $file_path = $level eq 'error' ? $error_log_path : $transaction_log_path;
    return 1 unless $file_path;

    open my $fh, '>>:encoding(UTF-8)', $file_path or do {
        CORE::warn "Unable to write legacy EDItX log $file_path: $!";
        return;
    };
    print {$fh} $self->getTimeStamp() . " -- [$level] " . $message . "\n";
    close $fh or CORE::warn "Unable to close legacy EDItX log $file_path: $!";

    return 1;
}

sub getTimeStamp {
    my $self = shift;

    return strftime( "%Y-%m-%d %H:%M:%S", localtime );
}

1;

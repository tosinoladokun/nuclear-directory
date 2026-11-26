#!/usr/bin/perl
# Filters a pg_restore SQL script (stdin to stdout) so it loads into any
# Postgres 16 (#968). Postgres 16.16 tags every column with an option,
# pg_attver, that it manages itself: 16.16's pg_dump leaves it out, but an
# older pg_dump run against a 16.16 server writes it out as
#
#   ALTER TABLE ONLY public.t ALTER COLUMN id SET (pg_attver=205353458720);
#
# and a server older than 16.16 refuses the whole restore. This removes that
# option, as 16.16's own pg_dump does, and keeps any other column option. A statement left with no options is
# dropped. COPY data is passed through untouched, whatever it contains.
# The number of options removed goes to stderr.
use strict;
use warnings;

my ($in_copy, $removed) = (0, 0);
while (my $line = <STDIN>) {
  if ($in_copy) {
    $in_copy = 0 if $line eq "\\.\n";
    print $line;
    next;
  }
  if ($line =~ /^COPY .* FROM stdin;$/) {
    $in_copy = 1;
    print $line;
    next;
  }
  if ($line =~ /^(ALTER TABLE (?:ONLY )?.+ ALTER COLUMN .+ SET \()(.*)(\);)$/) {
    my ($head, $options, $tail) = ($1, $2, $3);
    my @all = split /,\s*/, $options;
    my @kept = grep { !/^\s*pg_attver\s*=/ } @all;
    if (@kept < @all) {
      $removed += @all - @kept;
      print $head, join(", ", @kept), $tail, "\n" if @kept;
      next;
    }
  }
  print $line;
}
print STDERR "Removed ${removed} pg_attver column options.\n";

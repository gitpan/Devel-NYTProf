sub foo {
  my $x;
  my $y;
  print "in sub foo\n";
  for( $x = 1; $x < 100; ++$x ){
    bar();
    for( $y = 1; $y < 100; ++$y ){
      0;
    }
  }
}

sub bar {
  my $x;
  print "in sub bar\n";
  for( $x = 1; $x < 100; ++$x ){
    1;
  }
}

sub baz {
  print "in sub baz\n";
  eval { foo();  # counts as two executions
          bar(); }; # counts as one execution
}

eval { bar(); };  # two executions
baz();
eval "foo();";  # one vanilla execution, one eval execution

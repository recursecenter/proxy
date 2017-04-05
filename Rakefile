require 'rake/testtask'

Rake::TestTask.new do |t|
  t.libs += ["backend/lib", "test"]
  t.test_files = Dir["test/**/*_test.rb"]
end

desc "generate certs/dhparam.pem"
file "certs/dhparam.pem" do
  system("openssl dhparam -out certs/dhparam.pem 2048")
end

desc "generate certs/key.pem"
file "certs/key.pem" do
  system("openssl genrsa -out certs/key.pem 2048")
end

desc "generate certs/cert.pem"
file "certs/cert.pem" => ["certs/key.pem"] do
  system("openssl req -new -subj '/' -key certs/key.pem -out certs/csr.pem")
  system("openssl x509 -req -sha256 -days 1825 -in certs/csr.pem -signkey certs/key.pem -out certs/cert.pem")
  system("rm certs/csr.pem")
end

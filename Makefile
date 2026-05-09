THIRDPATY_URL ?= https://bench-dataset.oss-cn-beijing.aliyuncs.com/thirdpaty/benchmark_thirdpaty.tar.gz

.PHONY: help result dist clean thirdpaty
help:
	@echo "Available targets:"
	@echo "  result          - Generate the benchmark results HTML report"
	@echo "  dist            - Create a tar.gz archive of the benchmarks"
	@echo "  clean           - Remove generated benchmark archive"
	@echo "  thirdpaty       - Download and extract third-party tools"
	@echo "                   Override with THIRDPATY_URL=<url>"
	@echo "  help            - Show this help message"


result:
	bash $(CURDIR)/scripts/generate-html.sh

dist:
	tar -czf benchmarks.tar.gz -C .. \
		benchmarks/benchmarks \
		benchmarks/engines \
		benchmarks/lib \
		benchmarks/tools \
		benchmarks/benchmark.sh \
		benchmarks/Makefile \
		benchmarks/scripts

clean:
	rm -f benchmarks.tar.gz

thirdpaty:
	wget -nv $(THIRDPATY_URL) -O benchmark_thirdpaty.tar.gz
	tar -xzf benchmark_thirdpaty.tar.gz
	rm -f benchmark_thirdpaty.tar.gz
